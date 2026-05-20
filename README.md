# aws_xray_sdk

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

```yaml
# pubspec.yaml
dependencies:
  aws_xray_sdk: ^0.1.0
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

If you use the [`aws_lambda_dart_runtime_ns`](https://pub.dev/packages/aws_lambda_dart_runtime_ns)
community package (Dart 3, actively maintained), the runtime controls the event
loop and uses `package:http` internally. Wrap the runtime loop with
`invokeWithXRay()` to intercept the `Lambda-Runtime-Trace-Id` header, and wrap
each handler with `xRayHandler()`:

```dart
// main.dart
void main() async {
  final tracer = _setupTracer();
  XRay.patchHttp(tracer);  // must be before any HttpClient is created

  await invokeWithXRay(() => invokeAwsLambdaRuntime([
    xRayHandler(name: 'fn.handler', tracer: tracer, action: handleEvent),
  ]));
}

// xray_handler.dart — minimal integration shim
String _lambdaTraceHeader = '';

http.Client _capturingClient() => _TraceCapturingClient(http.Client());

class _TraceCapturingClient extends http.BaseClient {
  final http.Client _inner;
  _TraceCapturingClient(this._inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final res = await _inner.send(request);
    final h = res.headers['lambda-runtime-trace-id'];
    if (h != null && h.isNotEmpty) _lambdaTraceHeader = h;
    return res;
  }
}

Future<void> invokeWithXRay(Future<void> Function() fn) =>
    http.runWithClient(fn, _capturingClient);

FunctionHandler xRayHandler({
  required String name,
  required XRayTracer tracer,
  required FunctionAction action,
}) =>
    FunctionHandler(
      name: name,
      action: (ctx, event) => _traced(tracer, ctx, () => action(ctx, event)),
    );

Future<InvocationResult> _traced(
  XRayTracer tracer,
  RuntimeContext ctx,
  Future<InvocationResult> Function() fn,
) {
  final raw = _lambdaTraceHeader;
  final traceId = TraceId.tryParse(raw) ?? TraceId.generate();
  final parentId = TraceId.parseParentId(raw);
  final sampled = TraceId.parseSampled(raw) ?? true;
  if (parentId != null) {
    return tracer.runLambda(traceId, parentId, ctx.functionName, fn,
        sampled: sampled);
  }
  // Local dev / no runtime present
  final segment = Segment.begin(name: ctx.functionName, traceId: traceId);
  return tracer.run(segment, fn);
}
```

`invokeWithXRay` wraps the runtime's `package:http` calls so every
`/invocation/next` response is seen by `_TraceCapturingClient`, which stores
the authoritative `Lambda-Runtime-Trace-Id` header. `xRayHandler` reads that
stored value (always set before the handler fires) instead of the env var.

### Complete Lambda examples

See the workspace demos for fully deployable CDK applications:

- [`demos/lambda/`](../demos/lambda/) — hand-rolled runtime, reads trace header directly from HTTP responses
- [`demos/lambda_dart_runtime/`](../demos/lambda_dart_runtime/) — `aws_lambda_dart_runtime_ns` package, header captured via `http.runWithClient()`

---

## Sampling

```dart
// Fixed rate — sample N% of all requests
XRayTracer(sampling: FixedRateSampler(0.05))  // 5 %

// Reservoir — keep up to N traces/second, then fall back to fixed rate
XRayTracer(sampling: ReservoirSampler(reservoirSize: 50, fixedRate: 0.05))

// Custom strategy
class MyRuleSampler implements SamplingStrategy {
  @override
  bool shouldSample(SamplingRequest req) =>
      req.urlPath.startsWith('/checkout');  // always trace checkouts
}
```

---

## Sender options

| Sender | Description |
|---|---|
| `UdpSender` (default) | Fire-and-forget UDP to the X-Ray daemon (`127.0.0.1:2000`) |
| `NoopSender` | Discards all segments; useful for tests and local dev |
| `HttpApiSender` | PutTraceSegments HTTP API — **stub, pending SigV4 signing** |

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
  finally block
       │
       ├── encode(segment)         1 packet if ≤64 KB, else skeleton + subsegment docs
       │
       └── UdpSender.send          fire-and-forget UDP → 127.0.0.1:2000
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
    tracer.dart                  # XRayTracer  — run(), runLambda(), subsegment API
    xray.dart                    # XRay facade — patchHttp(), fromClient<T>()
    utils.dart                   # randomHex(), nowSeconds()
    models/
      segment.dart               # Segment       (immutable value object)
      subsegment.dart            # Subsegment    (immutable value object)
      trace_id.dart              # TraceId       — generate, parse, header fields
      http_data.dart             # HttpData, HttpRequestData, HttpResponseData
      aws_data.dart              # AwsData       — operation, tableName, …
      cause.dart                 # Cause + XRayException
      sql_data.dart              # SqlData
    sampling/
      sampling_strategy.dart     # SamplingRequest, SamplingStrategy interface
      fixed_rate_sampler.dart    # FixedRateSampler
      reservoir_sampler.dart     # ReservoirSampler
    sender/
      sender.dart                # Sender abstract class  (send, close, sendPackets)
      udp_sender.dart            # UdpSender     — fire-and-forget UDP
      http_api_sender.dart       # HttpApiSender — stub (pending SigV4)
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
