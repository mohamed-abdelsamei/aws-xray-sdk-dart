# X-Ray SDK Dart — Examples

Runnable examples for the `aws_xray_sdk` package.  Each file can be executed
with `dart run` from the `aws_xray_sdk_dart/` directory.

## Quick start

```bash
cd aws_xray_sdk_dart
dart pub get
dart run example/basic_usage.dart
```

Every example runs to completion without a daemon and prints to stdout. They
differ only in sender:

- **`NoopSender`** (`advanced_tracing`, `error_handling`, `manual_instrumentation`,
  `sampling_strategies`, `zero_config`, `lambda_runtime`) — discards segments.
- **`UdpSender`** (`basic_usage`, `http_tracing`, `package_http_tracing`,
  `server_middleware`) — fires to `127.0.0.1:2000`. With no daemon listening the
  datagram is silently dropped, so the program still exits cleanly; start the
  daemon below to actually see the traces.
- **`InMemorySender`** (`aws_sdk_tracing`) — captures segments so the example can
  print the subsegments it produced.

Start a local daemon to receive the `UdpSender` traces:

```bash
# Run the X-Ray daemon locally (Docker)
docker run --rm -p 2000:2000/udp amazon/aws-xray-daemon -o
```

---

## Examples

### 1. [basic_usage.dart](basic_usage.dart)

The minimal end-to-end path: create a tracer, then `tracer.trace(name, fn)` —
one call that begins the segment, runs the block, closes, and sends.

```bash
dart run example/basic_usage.dart
```

### 1b. [zero_config.dart](zero_config.dart)

The fastest setup: `XRay.configure()` reads the AWS environment, installs the
process-wide default tracer (`XRay.tracer`), and patches HTTP in one idempotent
call — then `XRay.trace()` / `XRay.capture()` / `XRay.annotate()` trace work
anywhere with no tracer threading.  Also shows `XRay.aws()` for
`aws_client` / `aws_*_api` clients and `XRay.reset()`.

```bash
dart run example/zero_config.dart
```

### 2. [http_tracing.dart](http_tracing.dart)

Automatic HTTP tracing via `XRay.patchHttp()`.  After a single call at startup
every `HttpClient` opened in the process — including those inside third-party
packages — is wrapped by `XRayHttpClient`, which:

- opens a subsegment named by the target host
- injects `X-Amzn-Trace-Id` into the outbound request
- records HTTP method, URL, and response status
- marks the subsegment `error=true` on 4xx, `fault=true` on 5xx

**Important**: call `XRay.patchHttp()` exactly once.  Double-patching wraps
`XRayHttpClient` inside itself and produces duplicate subsegments for every
request.

```bash
dart run example/http_tracing.dart
```

### 2b. [package_http_tracing.dart](package_http_tracing.dart)

Tracing `package:http` clients by wrapping them with `XRayBaseClient` — the
counterpart to the `dart:io` patch above.  Use this when a library or AWS SDK
(`aws_client` / `aws_*_api`) takes an `http.Client`: hand it a wrapped client
and every request gets a subsegment with the trace header injected.

```bash
dart run example/package_http_tracing.dart
```

### 3. [aws_sdk_tracing.dart](aws_sdk_tracing.dart)

Wrapping a Smithy-generated AWS SDK client with `XRay.registerClient` /
`XRay.fromClient`.  Uses a stub `DynamoDbClient` so it runs without a real
Smithy dependency; replace the stub with the real client in your app.  Traces a
successful and a failing call, then prints the captured subsegments (via
`InMemorySender`) so you can see exactly what gets sent to the daemon.

Key points:

- `requestAdapter` — extracts operation name, method, URL, and a
  `withTraceHeader` callback that injects `X-Amzn-Trace-Id` into the request
- `responseAdapter` — maps `statusCode`, `requestId` (→ `aws.request_id`),
  `region`, and `errorCode` onto the subsegment
- `extractor` — pulls the AWS resource (here the table) out of the request body
  into `aws.*` fields (only needed for custom/stub types; built-in extractors
  cover the real clients)
- `rebuild` — extracts the client's internal send function, wraps it, and
  returns a new client instance via `copyWith`
- a thrown service error is recorded as `fault=true` with its `cause`

If you use a community HTTP-based AWS client (e.g. `aws_dynamodb_api` from
pub.dev), skip `registerClient` entirely — `XRay.patchHttp()` already traces
every request to `*.amazonaws.com` with `namespace='aws'`.

```bash
dart run example/aws_sdk_tracing.dart
```

### 4. [advanced_tracing.dart](advanced_tracing.dart)

Structuring a trace: nested `captureAsync` blocks vs. the manual
`beginSubsegment` / `endSubsegment` / `failSubsegment` lifecycle.

**Subsegment model**: `captureAsync(name, fn)` forks a child scope, so
everything traced inside it — manual spans and auto-instrumented HTTP/AWS
calls — nests under it in the trace tree, and an uncaught error marks it
faulted automatically.  Manual subsegments attach under whatever scope is
active when they open: flat siblings at the top level, children inside a
`captureAsync` block.

```bash
dart run example/advanced_tracing.dart
```

### 5. [sampling_strategies.dart](sampling_strategies.dart)

Comparing `FixedRateSampler` and `ReservoirSampler`.  Shows how the sampling
decision is made once at `tracer.trace()` / `run()` entry and propagated to all child
subsegments via the Zone.

```bash
dart run example/sampling_strategies.dart
```

### 6. [error_handling.dart](error_handling.dart)

How the SDK records errors, faults, and throttle responses:

| Condition | Segment field |
|---|---|
| 4xx (client error) | `error = true` |
| 429 (throttled) | `error = true`, `throttle = true` |
| 5xx (server fault) | `fault = true` |
| Unhandled exception | `fault = true`, `cause` object |

Also the one example that uses `tracer.run()` with a pre-built `Segment` —
the intended pattern when flags (`withError` / `withFault` / `withThrottle`)
must be applied before the segment runs; everywhere else prefer
`tracer.trace()`.

```bash
dart run example/error_handling.dart
```

### 7. [server_middleware.dart](server_middleware.dart)

Server-side request tracing with `handleTraced()` — one call per incoming
request that parses the upstream `X-Amzn-Trace-Id` header, opens the segment,
runs the handler inside it, and sets the response trace header for downstream
propagation.  The standard entry-point pattern for `dart:io` HTTP servers;
nested work inside a handler uses `captureAsync`.

```bash
dart run example/server_middleware.dart
```

### 8. [manual_instrumentation.dart](manual_instrumentation.dart)

Manual instrumentation for non-AWS code: annotations, metadata, manual
subsegments, and custom sampling — without any AWS SDK client involved.
Useful when wrapping a database driver or internal library.

```bash
dart run example/manual_instrumentation.dart
```

### 9. [lambda_runtime.dart](lambda_runtime.dart)

Complete AWS Lambda custom runtime with X-Ray tracing.  This is the reference
implementation for the `provided:al2023` base image pattern.

Key points:

1. **`runLambda()` instead of `run()`** — `provided:al2023` auto-creates an
   `AWS::Lambda::Function` segment.  Sending a competing top-level segment
   causes the daemon to silently drop one of them.  `runLambda()` emits an
   independent *subsegment document* parented to Lambda's auto-created segment
   so both appear correctly in the console.

2. **Read `AWS_XRAY_DAEMON_ADDRESS` at runtime** — newer Lambda environments
   use `169.254.100.1:2000` (link-local), not `127.0.0.1:2000`.  Hardcoding
   the address causes all UDP packets to be silently dropped.

3. **`XRay.patchHttp()` exactly once at cold start** — call it before any
   `HttpClient` is constructed; do not call it again inside the event loop.

Resulting trace structure:

```
AWS::Lambda (facade)                    [auto]
  AWS::Lambda::Function                 [auto — id from Parent= in header]
    Overhead                            [auto]
    my-function                         ← runLambda() subsegment ✓
      validate-input                    ← manual subsegment, namespace=aws
      jsonplaceholder.typicode.com      ← auto-traced HTTP, namespace=remote
      DynamoDB                          ← XRayBaseClient, namespace=aws (PutItem)
```

```bash
dart run example/lambda_runtime.dart
```

---

## Common patterns

### Swap the transport

```dart
// Development / CI — discard all segments
sender: NoopSender()

// Production — send to local X-Ray daemon via UDP
sender: UdpSender(host: '127.0.0.1', port: 2000)

// Lambda — let XRay.configure() read AWS_XRAY_DAEMON_ADDRESS for you
XRay.configure(); // parses the daemon address (IPv6-safe) + function name
```

### Annotations vs metadata

```dart
// Annotations — indexed, searchable in the X-Ray console filter bar.
// Keys allow only [A-Za-z0-9_]; any other char is sanitized to '_'
// ('http.status' would become 'http_status'), so use '_' directly.
segment.annotate('user_id', 'u-12345');
segment.annotate('http_status', 200);

// Metadata — arbitrary JSON, visible in the console but not searchable
subsegment.addMetadata('orderId', 'order-abc-123');
subsegment.addMetadata('amountCents', 4999);
```

### Library code without an explicit tracer parameter

When writing library code you shouldn't need to accept an `XRayTracer`
parameter.  Use the process-wide `XRay.tracer` (a no-op until `XRay.configure`
runs, so this is always safe), and `tracer.currentSegment` to check whether a
trace is active in the current Zone:

```dart
final tracer = XRay.tracer;              // global default; no-op if unconfigured

if (tracer.currentSegment != null) {     // are we inside a trace zone?
  final sub = tracer.beginSubsegment('my-library-op');
  try {
    // ... do work ...
    tracer.endSubsegment(sub);
  } catch (e) {
    tracer.failSubsegment(sub, e);
    rethrow;
  }
}
```

### Tracing outbound HTTP automatically

```dart
// Once at startup — affects all HttpClient instances created after this call.
XRay.patchHttp(tracer);

// In tests — restore previous overrides to avoid cross-test leakage.
XRay.unpatchHttp();
```
