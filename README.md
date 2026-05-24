# [aws_xray_sdk](https://pub.dev/packages/aws_xray_sdk)

A Dart package for distributed tracing with [AWS X-Ray](https://aws.amazon.com/xray/).

Traces outbound HTTP calls and AWS SDK operations, propagates the
`X-Amzn-Trace-Id` header, and delivers completed segments to the X-Ray daemon
via UDP — with first-class support for AWS Lambda custom runtimes.

---

## Features

| | |
|---|---|
| 🔍 **Automatic HTTP tracing** | Patch `dart:io` globally — every `HttpClient` call gets a subsegment with method, URL, and status |
| ☁️ **AWS SDK client wrapping** | Instrument any Smithy-generated client (DynamoDB, S3, KMS, …) via `XRay.fromClient<T>()` |
| λ **Lambda-native** | `runLambda()` attaches to the auto-created Lambda segment instead of competing with it |
| 📡 **UDP-first transport** | Fire-and-forget to the X-Ray daemon; reads `AWS_XRAY_DAEMON_ADDRESS` automatically |
| 🎛️ **Flexible sampling** | Fixed-rate and reservoir samplers; pluggable `SamplingStrategy` interface |
| 🔒 **Zone-based context** | Sampling decision and active segment flow across `await` chains with no manual threading |
| 🧊 **AOT / Flutter safe** | Zero `dart:mirrors`; no `build_runner` step |

---

## Installation

[![pub package](https://img.shields.io/pub/v/aws_xray_sdk.svg)](https://pub.dev/packages/aws_xray_sdk)

```yaml
# pubspec.yaml
dependencies:
  aws_xray_sdk: ^0.2.0
```

```bash
dart pub get
```

---

## Quick start

```dart
import 'package:aws_xray_sdk/aws_xray_sdk.dart';

final tracer = XRayTracer(serviceName: 'order-service');

Future<void> processOrder(String orderId) {
  final segment = Segment.begin(
    name: 'order-service',
    traceId: TraceId.generate(),
  );

  return tracer.run(segment, () async {
    // All HttpClient calls inside this closure are traced automatically.
    final result = await fetchInventory(orderId);
    return result;
  });
}
```

---

## HTTP auto-tracing

Call `XRay.patchHttp(tracer)` **once at startup**. Every `HttpClient` created
afterwards — including those inside third-party packages that use
`package:http`'s `IOClient` — is automatically wrapped.

```dart
void main() async {
  final tracer = XRayTracer(serviceName: 'my-service');
  XRay.patchHttp(tracer);          // patch dart:io globally

  final segment = Segment.begin(name: 'my-service', traceId: TraceId.generate());
  await tracer.run(segment, () async {
    // This HttpClient call produces a subsegment automatically:
    //   name: 'api.example.com'
    //   namespace: 'remote'   (or 'aws' for *.amazonaws.com)
    //   http.request.method / url
    //   http.response.status
    final client = HttpClient();
    final req = await client.getUrl(Uri.parse('https://api.example.com/data'));
    final res = await req.close();
    client.close();
  });
}
```

To stop tracing: `XRay.unpatchHttp()`.

---

## Manual subsegments

```dart
await tracer.run(segment, () async {
  // Instrument any synchronous or async block:
  final sub = tracer.beginSubsegment('parse-payload');
  try {
    final result = heavyParsing(data);
    tracer.endSubsegment(sub.addMetadata('recordCount', result.length));
    return result;
  } catch (e) {
    tracer.failSubsegment(sub, e);   // marks fault=true, records exception
    rethrow;
  }
});
```

### Recording errors on the segment itself

`Segment` mirrors the `Subsegment` error API — pass an optional exception to
capture it in the X-Ray `cause` block:

```dart
final segment = tracer.beginSegment();
try {
  await tracer.run(segment, fn);
} catch (e) {
  await tracer.closeSegment(segment.withFault(e));  // fault=true + cause
}
```

---

## AWS SDK client wrapping

Register a descriptor once at cold-start, then wrap any instance:

```dart
// 1. Register (once, at startup)
XRay.registerClient<DynamoDbClient>(
  requestAdapter: (req) {
    final r = req as DdbReq;
    return (operationName: r.operation, method: 'POST', url: r.endpoint, resource: r.tableName);
  },
  responseAdapter: (res) => (statusCode: (res as DdbRes).statusCode, contentLength: null),
  rebuild: (client, wrapSend) {
    final inner = (req) => client.rawSend(req as DdbReq);
    return client.copyWith(httpSend: wrapSend(inner));
  },
);

// 2. Wrap (per instance)
final ddb = XRay.fromClient(DynamoDbClient(...), tracer: tracer);
await ddb.getItem(...);  // subsegment created automatically
```

---

## Lambda integration

Lambda's `provided:al2023` runtime automatically creates an
`AWS::Lambda::Function` segment. Sending a second top-level segment conflicts
and is silently dropped by the daemon. Use `runLambda()` instead — it emits an
independent **subsegment document** parented to Lambda's auto-created segment.

```dart
// In your Lambda runtime loop, after parsing the Lambda-Runtime-Trace-Id header:
final rawHeader = ctx.traceId ?? '';
final traceId   = TraceId.tryParse(rawHeader) ?? TraceId.generate();
final parentId  = TraceId.parseParentId(rawHeader);   // 'Parent=' field
final sampled   = TraceId.parseSampled(rawHeader) ?? true;

if (parentId != null) {
  await tracer.runLambda(traceId, parentId, functionName, fn, sampled: sampled);
} else {
  // Local testing fallback — no Lambda runtime present.
  final segment = Segment.begin(name: functionName, traceId: traceId);
  await tracer.run(segment, fn);
}
```

**Resulting X-Ray trace:**
```
AWS::Lambda (facade)                [auto]
  AWS::Lambda::Function             [auto — id from Lambda-Runtime-Trace-Id]
    Overhead                        [auto]
    <function-name>                 ← our handler subsegment ✓
      validation                    ← manual subsegment
      dynamodb.us-east-1.amazonaws.com  ← auto HTTP, namespace=aws
      api.downstream.com            ← auto HTTP, namespace=remote
```

### Trace header source

Always read the trace context from the `Lambda-Runtime-Trace-Id` **HTTP
response header** returned by the Runtime API's `/invocation/next` call —
not from `_X_AMZN_TRACE_ID` (the process environment variable).

Lambda sets both per invocation, but they often carry **different trace IDs**:
the env var reflects the incoming request trace (e.g. from API Gateway), while
the header carries the function-level trace ID that Lambda's auto-created
`AWS::Lambda::Function` segment uses. Reading from the env var causes your
subsegment document to land in a separate, unlinked trace.

```
❌  Platform.environment['_X_AMZN_TRACE_ID']  // incoming request trace ID
✅  nextRes.headers.value('lambda-runtime-trace-id')  // function-level trace ID
```

### Daemon address

Lambda injects the daemon address via `AWS_XRAY_DAEMON_ADDRESS`. Do **not**
hardcode `127.0.0.1:2000` — newer Lambda environments use a link-local address
(`169.254.100.1:2000`). The recommended setup:

```dart
(String host, int port) _daemonAddress() {
  final raw = Platform.environment['AWS_XRAY_DAEMON_ADDRESS'] ?? '127.0.0.1:2000';
  final colon = raw.lastIndexOf(':');
  return colon == -1 ? (raw, 2000) : (raw.substring(0, colon), int.parse(raw.substring(colon + 1)));
}

final tracer = XRayTracer(
  serviceName: Platform.environment['AWS_LAMBDA_FUNCTION_NAME'] ?? 'my-function',
  sender: UdpSender(host: host, port: port),
  sampling: FixedRateSampler(1.0),  // Lambda decides sampling; always forward to daemon
);
```

### Using `aws_lambda_dart_runtime_ns`

A minimal shim for the [`aws_lambda_dart_runtime_ns`](https://pub.dev/packages/aws_lambda_dart_runtime_ns)
package intercepts the `Lambda-Runtime-Trace-Id` header and wraps each handler
with `runLambda`:

```dart
String _lambdaTraceHeader = '';

// Wrap the runtime loop to capture the trace header from /invocation/next:
Future<void> invokeWithXRay(Future<void> Function() fn) =>
    http.runWithClient(fn, () {
      final inner = http.Client();
      return http.BaseClient()
        ..send = (req) async {
          final res = await inner.send(req);
          final h = res.headers['lambda-runtime-trace-id'];
          if (h != null && h.isNotEmpty) _lambdaTraceHeader = h;
          return res;
        };
    }());

FunctionHandler xRayHandler({required XRayTracer tracer, required FunctionAction action}) =>
    FunctionHandler(
      name: 'xray',
      action: (ctx, event) async {
        final raw = _lambdaTraceHeader;
        final traceId = TraceId.tryParse(raw) ?? TraceId.generate();
        final parentId = TraceId.parseParentId(raw);
        if (parentId != null) {
          return tracer.runLambda(traceId, parentId, ctx.functionName,
              () => action(ctx, event),
              sampled: TraceId.parseSampled(raw) ?? true);
        }
        final segment = Segment.begin(name: ctx.functionName, traceId: traceId);
        return tracer.run(segment, () => action(ctx, event));
      },
    );

void main() async {
  final tracer = XRayTracer(serviceName: 'my-function');
  XRay.patchHttp(tracer);
  await invokeWithXRay(() => invokeAwsLambdaRuntime([
    xRayHandler(tracer: tracer, action: handleEvent),
  ]));
}
```

### Complete Lambda examples

See the workspace demos for fully deployable CDK applications:

- [`demos/lambda/`](../demos/lambda/) — hand-rolled runtime, reads trace header directly from HTTP responses
- [`demos/lambda_dart_runtime/`](../demos/lambda_dart_runtime/) — `aws_lambda_dart_runtime_ns` package, header captured via `http.runWithClient()`

---

## Sampling

The sampling decision is made once at `tracer.run()` entry and stored in the
zone so every downstream header injection uses the same `Sampled=1/0` flag.
Pass `httpMethod` and `urlPath` to `run()` to give the sampler contextual info:

```dart
await tracer.run(segment, fn, httpMethod: 'POST', urlPath: '/checkout');
```

```dart
// Fixed rate — sample N% of all requests
XRayTracer(sampling: FixedRateSampler(0.05))  // 5 %

// Reservoir — keep up to N traces/second, then fall back to fixed rate
XRayTracer(sampling: ReservoirSampler(reservoirSize: 50, fixedRate: 0.05))

// Custom strategy — sample based on request properties
class MyRuleSampler implements SamplingStrategy {
  @override
  bool shouldSample(SamplingRequest req) =>
      req.urlPath.startsWith('/checkout');
}
```

---

## Sender options

| Sender | Description |
|---|---|
| `UdpSender` (default) | Fire-and-forget UDP to the X-Ray daemon (`127.0.0.1:2000`) |
| `NoopSender` | Discards all segments; useful for tests and local dev |

> **Note:** `HttpApiSender` (PutTraceSegments HTTP API) is not exported — SigV4 request signing is not yet implemented. Use `UdpSender` for all deployments.

```dart
// Tests — discard all segments
XRayTracer(sender: NoopSender());

// Custom daemon host (e.g. container-based setup)
XRayTracer(sender: UdpSender(host: 'xray-daemon.local', port: 2000));
```

---

## Segment document schema

The SDK emits JSON that conforms to the
[X-Ray segment document schema](https://docs.aws.amazon.com/xray/latest/devguide/xray-api-segmentdocuments.html).
Key fields:

```json
{
  "trace_id": "1-5759e988-bd862e3fe1be46a994272793",
  "id": "70de5b6f19ff9a70",
  "name": "order-service",
  "start_time": 1461096053.37518,
  "end_time":   1461096053.40701,
  "subsegments": [
    {
      "id": "4cd3d1ec0a974eef",
      "name": "api.example.com",
      "namespace": "remote",
      "http": {
        "request":  { "method": "GET", "url": "https://api.example.com/data" },
        "response": { "status": 200 }
      }
    }
  ]
}
```

Oversized segments (> 64 KB) are automatically split into a skeleton segment
plus one independent subsegment document per subsegment.

---

## Architecture

```
Application code
       │
       ▼
XRayTracer.run / runLambda        Zone stores: Segment, []Subsegment, sampled
       │
       ├──── beginSubsegment / endSubsegment / failSubsegment  (manual)
       │
       ├──── XRayHttpClient        (auto via XRay.patchHttp)
       │         └─ openUrl → beginSubsegment, inject X-Amzn-Trace-Id
       │         └─ close  → endSubsegment with status
       │
       └──── XRayInterceptor       (auto via XRay.fromClient<T>)
                 └─ wrap send fn → beginSubsegment, await, endSubsegment
       │
       ▼
   finally block (run path)        runLambda path
       │
       ├── encode(segment)         encodeSubsegmentDoc()
       │                           (independent subsegment)
       └── UdpSender.send          UdpSender.sendPackets
           fire-and-forget UDP → 127.0.0.1:2000
```

**Zone-based context** means you never pass the tracer or segment through
function arguments. Any code that runs inside `tracer.run(…)` — including
library code — can call `tracer.currentSegment` to get the active segment.

---

## Running the X-Ray daemon locally

```bash
# Docker (recommended)
docker run --rm -p 2000:2000/udp -p 2000:2000 \
  amazon/aws-xray-daemon -o   # -o = no EC2 metadata lookup

# macOS (Homebrew)
brew install aws-xray-daemon && xray

# View traces
open https://console.aws.amazon.com/xray/home
```

---

## Package layout

```
lib/
  aws_xray_sdk.dart              # public barrel export
  src/
    tracer.dart                  # XRayTracer  — run(), runLambda(), _runZoned(), subsegment API
    xray.dart                    # XRay facade — patchHttp(), fromClient<T>()
    utils.dart                   # randomHex(), nowSeconds()
    models/
      segment.dart               # Segment       (immutable value object; aws typed as AwsData)
      subsegment.dart            # Subsegment    (immutable value object)
      trace_id.dart              # TraceId       — generate, parse, header fields
      http_data.dart             # HttpData, HttpRequestData, HttpResponseData
      aws_data.dart              # AwsData       — operation, tableName, …
      cause.dart                 # Cause + XRayException
      sql_data.dart              # SqlData
    sampling/
      sampling_strategy.dart     # SamplingRequest, SamplingStrategy interface
      fixed_rate_sampler.dart    # FixedRateSampler
      reservoir_sampler.dart     # ReservoirSampler  (one instance per isolate)
    sender/
      sender.dart                # Sender abstract class  (send, close, sendPackets)
      udp_sender.dart            # UdpSender     — fire-and-forget UDP
      http_api_sender.dart       # HttpApiSender — not exported; stub pending SigV4
      noop_sender.dart           # NoopSender    — discard (tests / dev)
      segment_encoder.dart       # encode(), encodeSubsegmentDoc()
    http/
      xray_http_client.dart      # XRayHttpClient  — wraps dart:io HttpClient
      xray_http_overrides.dart   # XRayHttpOverrides — global dart:io patch
    wrappers/
      xray_interceptor.dart      # XRayInterceptor<Req,Res>, buildTraceHeader()
      client_registry.dart       # ClientDescriptor, clientRegistry
      resource_extractor.dart    # ResourceExtractor — DDB/S3/KMS/SQS/SNS
      aws_service_names.dart     # client type → X-Ray namespace string
```

---

## Roadmap

### In progress / known stubs

| Item | File | Notes |
|---|---|---|
| `HttpApiSender` SigV4 signing | `sender/http_api_sender.dart` | Throws `UnimplementedError`; class is not exported. Implement AWS SigV4 request signing to enable the PutTraceSegments HTTP API path. |
| `SqlData` wiring | `models/sql_data.dart` | Model is complete but nothing populates it. Needs a database driver interceptor (e.g. a `postgres` / `sqflite` wrapper). |

### Planned features

| Feature | Priority | Description |
|---|---|---|
| Server-side trace middleware | High | Parse `X-Amzn-Trace-Id` from incoming HTTP requests, create/continue a `Segment`, and inject the header into responses. Shelf and `dart:io` `HttpServer` variants. |
| `package:http` `BaseClient` wrapper | Medium | `XRayHttpClient` covers `dart:io` and `package:http`'s `IOClient`, but not browser or custom `BaseClient` subclasses. A `XRayBaseClient` wrapper would fill this gap. |
| Dynamic sampling rules (X-Ray API) | Medium | Poll the X-Ray `GetSamplingRules` / `GetSamplingTargets` API and apply centrally managed rules, matching the behaviour of the official SDKs. |
| X-Ray groups and filter expressions | Low | Support emitting `service` and `origin` metadata that X-Ray filter expressions can target for trace grouping and alerting. |
| `TracedSpan` mixin / base class | Low | `Segment` and `Subsegment` share ~150 lines of identical fields and `_copyWith` / `toJson` logic. Extracting a common mixin would reduce duplication and make future field additions cheaper. |
| `segment.namespace` field | Low | X-Ray segment documents accept a top-level `namespace` field. `Subsegment` already has one; `Segment` does not. |
| Injected clock for testing | Low | `nowSeconds()` reads `DateTime.now()` directly, making timing-sensitive tests depend on wall-clock sleep. An injectable clock would allow deterministic tests with no `Future.delayed`. |
| `X-Amzn-Trace-Id` response header propagation | Low | Outbound requests inject the trace header, but server responses do not. Downstream services lose continuity when the SDK runs in a server role. |
| Response body stream error capture | Low | `_TracedRequest.close()` records the HTTP status before the body stream is consumed; a streaming error during `drain()` is invisible to X-Ray. |

---

## Contributing

```bash
git clone https://github.com/mohamed-abdelsamei/aws-xray-sdk-dart.git
cd aws-xray-sdk-dart
dart pub get
dart test                         # run all tests
dart analyze --fatal-warnings     # must pass clean
dart format .                     # format code
```

---

## License

MIT — see [LICENSE](LICENSE).
