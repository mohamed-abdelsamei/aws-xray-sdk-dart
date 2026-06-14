# [aws_xray_sdk](https://pub.dev/packages/aws_xray_sdk)

A Dart package for distributed tracing with [AWS X-Ray](https://aws.amazon.com/xray/).

Traces outbound HTTP calls and AWS SDK operations, propagates the
`X-Amzn-Trace-Id` header, and delivers completed segments to the X-Ray daemon
via UDP — with first-class support for AWS Lambda custom runtimes.

**Contents:**
[Install](#installation) ·
[Quick start](#quick-start) ·
[HTTP tracing](#http-tracing) ·
[`captureAsync`](#nested-subsegments--captureasync) ·
[Manual subsegments](#manual-subsegments) ·
[AWS SDK clients](#aws-sdk-client-wrapping) ·
[Lambda](#lambda-integration) ·
[Sampling](#sampling) ·
[Sender options](#sender-options) ·
[Schema](#segment-document-schema) ·
[Architecture](#architecture) ·
[Local dev](#local-development)

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
| 🧊 **AOT-safe** | Zero `dart:mirrors`; no `build_runner` step — compiles with `dart compile exe` |

---

## Installation

[![pub package](https://img.shields.io/pub/v/aws_xray_sdk.svg)](https://pub.dev/packages/aws_xray_sdk)

```bash
dart pub add aws_xray_sdk
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

## HTTP tracing

Two ways to trace outbound HTTP, both injecting `X-Amzn-Trace-Id`, recording
the request URL and response status, marking HTTP errors, and closing the
subsegment when the response body stream finishes.

### `dart:io` — global patch

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

### `package:http` — wrap a client

Wrap any `package:http` `Client` with `XRayBaseClient`:

```dart
final client = XRayBaseClient(http.Client(), tracer);
await tracer.run(segment, () => client.get(Uri.parse('https://api.example.com')));
```

`XRayBaseClient` injects the trace header into the `http.BaseRequest` it sends.
Treat `package:http` request objects as single-use, as intended by the package;
re-sending the same request instance can reuse the first attempt's `Parent=` id.

### Response-body lifecycle

If a response body is never drained, the SDK does **not** drop the span. At
trace finalization it emits the subsegment once, closed, with
`metadata.xray.incomplete = true` and the request/response fields known so far.
This covers status-only callers, `HEAD`, and 204/304-style responses while still
letting body-stream errors mark the span as faulted when the body is consumed.

---

## Nested subsegments — `captureAsync`

`captureAsync` wraps a block as a subsegment and **nests** anything traced
inside it — manual subsegments *and* auto-instrumented HTTP/AWS calls become
children of it, so the X-Ray service map shows the real call tree:

```dart
await tracer.run(segment, () async {
  await tracer.captureAsync('process-order', (span) async {
    span.annotate('orderId', id);            // indexed — filterable in console
    span.addMetadata('items', cart.length);  // non-indexed detail

    await http.get(itemsUri);   // nested under 'process-order'
    await ddb.putItem(...);     // nested under 'process-order'
  });
});
```

The scope is bound to a forked `Zone`, so concurrent `captureAsync` calls (e.g.
inside `Future.wait`) stay independent — parallel branches don't tangle. An
uncaught error inside the block marks the subsegment as faulted and rethrows.

### Live annotations & metadata

`tracer.annotate(key, value)` and `tracer.addMetadata(key, value)` apply to
whatever is currently being traced — the active `captureAsync` subsegment, or
the segment itself at the top level:

```dart
await tracer.run(segment, () async {
  tracer.annotate('userId', userId);   // → segment annotations (indexed)
  tracer.addMetadata('region', 'us-east-1');
});
```

**Annotations** are indexed and searchable in the console via filter
expressions. X-Ray restricts them, and the SDK enforces the rules by
**sanitizing rather than throwing** (a bad annotation never drops the trace):

- **Keys** may contain only `A-Z`, `a-z`, `0-9`, and `_`. Any other character is
  replaced with `_` (so `'order.id'` becomes `'order_id'`).
- **Values** must be a scalar — `String`, `bool`, `int`, or `double`. Anything
  else is coerced to its `toString()` (so a `List` is stored as its text form).

**Metadata** is *not* indexed and *not* validated: the value may be any
JSON-serializable object (maps, lists, nested structures) — use it for richer
detail you don't need to filter on. Avoid the `AWS.` namespace prefix, which
X-Ray reserves for its own use. X-Ray also applies a soft limit of ~50
annotations per trace.

### Missing trace context

`tracer.annotate`, `addMetadata`, and the manual `beginSubsegment` /
`endSubsegment` API only record when called inside a `tracer.run()` /
`runLambda()` / `captureAsync()` zone. When there is no active trace, the data
would be dropped; `ContextMissingPolicy` controls what happens:

```dart
XRayTracer(
  serviceName: 'svc',
  // ignore       — drop silently (default; fire-and-forget)
  // logError     — write a diagnostic to stderr, then drop
  // runtimeError — throw a StateError (surfaces missing instrumentation in tests)
  contextMissingPolicy: ContextMissingPolicy.logError,
);
```

The auto-instrumented HTTP clients are intentionally exempt: called outside a
`run()` zone they pass the request through untraced rather than triggering the
policy. `tracer.currentSegment` is also exempt — it is a side-effect-free getter
that returns `null` to signal "no active trace".

---

## Manual subsegments

For flat, sibling subsegments (or when begin and end straddle a callback), use
the manual API. Each attaches under whatever scope is active when it is opened:

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
    return (
      operationName: r.operation,
      method: 'POST',
      url: r.endpoint,
      body: {'TableName': r.tableName},          // used for resource extraction
      // Inject X-Amzn-Trace-Id into the outbound request and return the copy.
      withTraceHeader: (original, header) =>
          original.rebuild(headers: {...original.headers, 'X-Amzn-Trace-Id': header}),
    );
  },
  responseAdapter: (res) {
    final r = res as DdbRes;
    return (
      statusCode: r.statusCode,
      contentLength: null,
      requestId: r.requestId,
      region: null,     // omitted here: derived from the request URL when possible
      errorCode: null,  // set for modeled AWS throttle/error responses if available
    );
  },
  rebuild: (client, wrapSend) {
    final inner = (req) => client.rawSend(req as DdbReq);
    return client.copyWith(httpSend: wrapSend(inner));
  },
);

// 2. Wrap (per instance)
final ddb = XRay.fromClient(DynamoDbClient(...), tracer: tracer);
await ddb.getItem(...);  // subsegment created automatically
```

The response adapter fields map directly to X-Ray metadata:

- `requestId` becomes `aws.request_id`, the primary AWS support correlation key.
- `region` becomes `aws.region`; if omitted, the SDK derives it from standard
  regional AWS hosts such as `dynamodb.us-east-1.amazonaws.com`.
- `errorCode` is used to mark AWS throttles even when the HTTP status is not
  `429`.

Registered client namespaces are normalized to X-Ray schema values. Use `aws`
for AWS service clients and `remote` for other downstream clients; legacy
`AWS::...` values are treated as `aws`.

> See [`example/aws_sdk_tracing.dart`](example/aws_sdk_tracing.dart) for a
> complete, runnable version with a stub client.

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

### Complete Lambda example

See [`example/lambda_runtime.dart`](example/lambda_runtime.dart) for a runnable
reference showing how to read the `Lambda-Runtime-Trace-Id` header and forward it
to `runLambda()`.

---

## Sampling

The sampling decision is made **once** at `tracer.run()` entry and stored in the
zone so every downstream header injection uses the same `Sampled=1/0` flag.
An unsampled trace is still built (so your code runs identically) but the
segment is never sent to the daemon. Pass `httpMethod` and `urlPath` to `run()`
to give the sampler contextual info:

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

### Sampler semantics

| Sampler | Decision rule |
|---|---|
| `FixedRateSampler(rate)` | Each request is an independent coin flip sampled with probability `rate` (via `Random.secure`). `0.0` = none, `1.0` = all. No per-second guarantee — low rates over low traffic can produce streaks of unsampled requests. |
| `ReservoirSampler(reservoirSize, fixedRate)` | The first `reservoirSize` requests **each calendar second** are always sampled; once that second's reservoir is exhausted, further requests fall back to a `fixedRate` coin flip. The reservoir resets every second. |

Both ignore the `SamplingRequest` fields by default; only a custom
`SamplingStrategy` reads them.

### Local-only — no centralized rules (yet)

These samplers are **local**: each isolate decides independently with no
coordination and **no call to the X-Ray sampling API**. There is no
centralized-rule fallback — the configured local strategy is always
authoritative, and `GetSamplingRules` / `GetSamplingTargets` are not consulted
(centralized sampling is a planned feature, see the Roadmap). Two consequences:

- **Per-isolate reservoir.** `ReservoirSampler`'s budget is per isolate, not per
  service: N isolates each admit up to `reservoirSize` traces/second. Give each
  isolate its own `XRayTracer`/`ReservoirSampler` (sharing one across isolates is
  unsupported and miscounts).
- **No active context ⇒ always sampled.** Code that builds a segment and calls
  `closeSegment` outside a `tracer.run()` zone is sampled fail-open (so a
  manually constructed segment is never silently dropped). Under Lambda, the
  `Sampled=` flag from the runtime trace header is forwarded as-is via
  `runLambda(..., sampled:)`.

---

## Sender options

| Sender | Description |
|---|---|
| `UdpSender` (default) | Fire-and-forget UDP to the X-Ray daemon (`127.0.0.1:2000`) |
| `NoopSender` | Discards all segments; useful for tests and local dev |

> **Note:** The package currently sends traces through the X-Ray daemon protocol
> (`UdpSender`). The PutTraceSegments HTTP API path is not shipped because SigV4
> signing is not implemented.

```dart
// Tests — discard all segments
XRayTracer(sender: NoopSender());

// Custom daemon host (e.g. container-based setup)
XRayTracer(sender: UdpSender(host: 'xray-daemon.local', port: 2000));
```

`UdpSender` never throws into your traced code — a resolution, bind, or send
failure is contained. To observe **local** send failures, pass an `onError`
callback (silent by default):

```dart
XRayTracer(
  sender: UdpSender(onError: (e) => log.warning('X-Ray send failed', e)),
);
```

### Traces not showing up?

UDP is **fire-and-forget with no delivery acknowledgment** — a datagram sent to
a daemon that isn't listening still succeeds locally, so the SDK cannot tell you
"the daemon didn't receive it" (and `onError` only fires on *local* failures
like an unreachable network or a failed DNS lookup). If segments aren't
appearing in the X-Ray console, work down this list:

1. **Is the daemon running and reachable?** Start it in verbose mode and watch
   its own logs for received segments: `amazon/aws-xray-daemon -o -l dev`.
2. **Is the address right?** The default is `127.0.0.1:2000`. On newer Lambda
   runtimes it is the link-local `AWS_XRAY_DAEMON_ADDRESS` (e.g.
   `169.254.100.1:2000`) — read it at cold start, don't hardcode.
3. **Is the segment sampled?** With `FixedRateSampler(0.05)` only ~5% of traces
   are sent. Use `FixedRateSampler(1.0)` while verifying.
4. **Did the segment close?** A segment is only sent after `run()` /
   `closeSegment()` completes. An un-awaited `run()` may exit before the flush.
5. **Are the daemon's AWS credentials/region valid?** The daemon (not the SDK)
   uploads to X-Ray; check its logs for `PutTraceSegments` errors.

Delivery can only be confirmed at the daemon or the X-Ray console — not from
inside the process.

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
XRayTracer.run / runLambda        Zone stores: Segment, TraceState (entity
       │                          tree + current scope), sampled
       │
       ├──── captureAsync(name, fn)         (nested; forks a child scope/zone)
       ├──── annotate / addMetadata         (mutate the current scope)
       ├──── beginSubsegment / endSubsegment / failSubsegment  (manual, flat)
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

## Package layout

```
lib/
  aws_xray_sdk.dart              # public barrel export
  src/
    tracer.dart                  # XRayTracer — run(), runLambda(), captureAsync(), annotate(), subsegment API
    xray.dart                    # XRay facade — patchHttp(), fromClient<T>(), registerClient<T>(), untracedHttpClient()
    trace_scope.dart             # TraceScope / TraceContext — live runtime entity tree (mutable, serialized at close)
    trace_suppression.dart       # runWithoutDartIoTracing() — avoids double-tracing under patchHttp
    utils.dart                   # randomHex(), nowSeconds()
    models/
      segment.dart               # Segment       (immutable value object)
      subsegment.dart            # Subsegment    (immutable value object)
      trace_id.dart              # TraceId       — generate, parse, header fields
      http_data.dart             # HttpData, HttpRequestData, HttpResponseData
      aws_data.dart              # AwsData       — operation, tableName, …
      cause.dart                 # Cause + XRayException
      annotation.dart            # annotation key/value sanitize + coerce helpers
    sampling/
      sampling_strategy.dart     # SamplingRequest, SamplingStrategy interface
      fixed_rate_sampler.dart    # FixedRateSampler
      reservoir_sampler.dart     # ReservoirSampler  (one instance per isolate)
    sender/
      sender.dart                # Sender abstract class  (send, close, sendPackets)
      udp_sender.dart            # UdpSender     — fire-and-forget UDP
      noop_sender.dart           # NoopSender    — discard (tests / dev)
      segment_encoder.dart       # encode(), encodeSubsegmentDoc()
    http/
      xray_http_client.dart      # XRayHttpClient  — wraps dart:io HttpClient
      xray_http_overrides.dart   # XRayHttpOverrides — global dart:io patch
      xray_base_client.dart      # XRayBaseClient — wraps package:http BaseClient
      xray_server_middleware.dart# handleTraced() — dart:io HttpServer request tracing
    wrappers/
      xray_interceptor.dart      # XRayInterceptor<Req,Res>, adapter records
      client_registry.dart       # internal descriptor registry
      resource_extractor.dart    # ResourceExtractor — DDB/S3/KMS/SQS/SNS
    aws/
      region.dart                # AWS endpoint region parsing
      throttle_codes.dart        # AWS throttling error-code detection
    trace_header.dart            # X-Amzn-Trace-Id formatter
```

---

## Roadmap

### In progress / known stubs

| Item | File | Notes |
|---|---|---|
| PutTraceSegments HTTP API sender | new sender module | Implement AWS SigV4 request signing to enable daemon-less delivery. |

### Planned features

| Feature | Priority | Description |
|---|---|---|
| Shelf server middleware | Medium | `handleTraced` already covers `dart:io` `HttpServer` (parses incoming `X-Amzn-Trace-Id`, continues the `Segment`, and injects the header into responses). A `package:shelf` middleware variant would extend this to that ecosystem. |
| Dynamic sampling rules (X-Ray API) | Medium | Poll the X-Ray `GetSamplingRules` / `GetSamplingTargets` API and apply centrally managed rules, matching the behaviour of the official SDKs. |
| X-Ray groups and filter expressions | Low | Support emitting `service` and `origin` metadata that X-Ray filter expressions can target for trace grouping and alerting. |
| `TracedSpan` mixin / base class | Low | `Segment` and `Subsegment` share ~150 lines of identical fields and `_copyWith` / `toJson` logic. Extracting a common mixin would reduce duplication and make future field additions cheaper. |
| Injected clock for testing | Low | `nowSeconds()` reads `DateTime.now()` directly, making timing-sensitive tests depend on wall-clock sleep. An injectable clock would allow deterministic tests with no `Future.delayed`. |

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

## Local development

Run the X-Ray daemon locally to push traces to the AWS X-Ray console:

### 1. Start the daemon

With Docker and an SSO profile:

```bash
./scripts/run-daemon.sh <profile-name>
```

Or manually with the `export-credentials` workaround:

```bash
eval "$(aws configure export-credentials --profile <your-profile> --format env)"
docker run --rm \
  -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN \
  -e AWS_REGION=us-east-1 \
  -p 2000:2000/udp \
  amazon/aws-xray-daemon:3.x -o -n us-east-1
```

### 2. Run an instrumented Dart program

```bash
# Basic traced operation
dart run example/basic_usage.dart

# Automatic dart:io HTTP tracing
dart run example/http_tracing.dart

# package:http tracing via XRayBaseClient
dart run example/package_http_tracing.dart

# Server-side tracing with handleTraced
dart run example/server_middleware.dart
```

### 3. View traces

Open the [X-Ray console](https://console.aws.amazon.com/xray/home) — segments
appear within ~10 seconds of the run.

---

## License

MIT — see [LICENSE](LICENSE).
