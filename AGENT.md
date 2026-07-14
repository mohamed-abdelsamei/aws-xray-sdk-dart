# AGENT.md — aws_xray_sdk (Dart)

Context for AI coding agents working on this package.

## What this is

`aws_xray_sdk` is a Dart package for distributed tracing with AWS X-Ray.
It sends trace segments to the X-Ray daemon via UDP, auto-instruments
`dart:io` HTTP clients, and wraps Smithy-generated AWS SDK clients.
First-class support for AWS Lambda custom runtimes (`provided:al2023`).

**Remote:** `git@github.com:mohamed-abdelsamei/aws-xray-sdk-dart.git`  
**pub.dev:** `https://pub.dev/packages/aws_xray_sdk`

---

## Commands

```bash
# Get dependencies
dart pub get

# Run all tests
dart test

# Run a single test file
dart test test/tracer_test.dart

# Run tests matching a name
dart test --name "subsegment"

# Lint — must pass clean (treat warnings as errors)
dart analyze --fatal-warnings

# Format
dart format .

# Check formatting without writing
dart format --output=none --set-exit-if-changed .

# Dry-run publish check
dart pub publish --dry-run

# Run X-Ray daemon locally (requires Docker + AWS SSO)
./scripts/run-daemon.sh [profile] [region]
```

---

## Package layout

```
lib/
  aws_xray_sdk.dart          # barrel export — public API surface
  src/
    tracer.dart              # XRayTracer — Zone context, trace(), run(), runLambda(), captureAsync(), annotate(), subsegment API
    xray.dart                # XRay facade — trace(), capture(), patchHttp(), fromClient<T>(), untracedHttpClient()
    utils.dart               # randomHex(), nowSeconds()
    context/
      trace_scope.dart       # TraceScope / TraceContext — live mutable entity tree, serialized at close
      trace_suppression.dart # runWithoutDartIoTracing() — prevents double-tracing under patchHttp
    models/
      segment.dart           # Segment (immutable value object)
      subsegment.dart        # Subsegment (immutable value object)
      trace_id.dart          # TraceId — generate, tryParse, parseParentId, parseSampled
      trace_header.dart      # X-Amzn-Trace-Id formatter
      cause.dart             # Cause + XRayException
      http_data.dart         # HttpData, HttpRequestData, HttpResponseData
      aws_data.dart          # AwsData — operation, tableName, bucketName, …
      annotation.dart        # annotation key/value sanitize + coerce helpers
    sampling/
      sampling_strategy.dart # SamplingRequest, SamplingStrategy interface
      fixed_rate_sampler.dart
      reservoir_sampler.dart  # injectable clock for deterministic tests
    sender/
      sender.dart            # Sender abstract class (send, close, sendPackets)
      udp_sender.dart        # UdpSender — fire-and-forget UDP, resolve/bind once, onError hook
      noop_sender.dart       # NoopSender — discards all (local dev)
      in_memory_sender.dart  # InMemorySender — records segments + packets for test assertions
      segment_encoder.dart   # encode(), encodeSubsegmentDoc() — 64 KB split logic
    http/
      xray_http_client.dart  # XRayHttpClient — wraps dart:io HttpClient
      xray_http_overrides.dart # XRayHttpOverrides — global dart:io patch
      xray_base_client.dart  # XRayBaseClient — wraps package:http BaseClient
      xray_server_middleware.dart # handleTraced() — dart:io HttpServer request tracing
    wrappers/
      xray_interceptor.dart  # XRayInterceptor<Req,Res>, adapter records
      client_registry.dart   # internal descriptor registry, XRayWrapFn
      resource_extractor.dart# ResourceExtractor — DDB/S3/KMS/SQS/SNS
    lambda/
      lambda_trace_capture.dart # LambdaTraceCapture — captures Lambda-Runtime-Trace-Id per invocation
    aws/
      region.dart            # AWS endpoint host/region parsing (isAwsHost, regionFromAwsHost)
      throttle_codes.dart    # AWS throttling error-code detection
test/                        # mirrors lib/src/ structure
example/                     # pub.dev examples (11 files + README.md)
scripts/
  run-daemon.sh              # start X-Ray daemon via Docker with SSO creds
.github/
  workflows/
    ci.yml                   # push/PR to main: format + analyze + test (stable + beta)
    commitlint.yml           # PR: Conventional Commit title check
    tag-release.yml          # "Release" button: validate, push vX.Y.Z tag, dispatch publish
    publish.yml              # tag v*.*.*: test -> GitHub Release -> pub publish (OIDC)
```

---

## Architecture

### Data flow — standalone

1. `tracer.run(segment, fn)` makes the sampling decision **once**, stores
   `Segment`, `TraceState`, the current `TraceScope`, and `bool sampled` in a
   Dart `Zone`.
2. Inside `fn`, outbound calls go through one of three paths, each opening a
   subsegment, injecting `X-Amzn-Trace-Id`, awaiting, then closing it:
   `XRayHttpClient` (dart:io, auto via `XRay.patchHttp`), `XRayBaseClient`
   (package:http), or `XRayInterceptor` (Smithy clients via
   `XRay.fromClient<T>()`). `captureAsync(name, fn)` groups them under a named
   nested subsegment. Higher-level wrappers run their inner send through
   `runWithoutDartIoTracing` so a patched dart:io client underneath does not
   trace the same request twice.
3. On completion the segment is JSON-serialised, wrapped with
   `{"format":"json","version":1}\n`, and fired as a UDP datagram to the
   X-Ray daemon (`127.0.0.1:2000` by default).

### Data flow — AWS Lambda (`runLambda`)

Lambda auto-creates an `AWS::Lambda::Function` segment. Competing with it
causes silent drops. Use `runLambda()` instead — it emits an independent
**subsegment document** (`"type":"subsegment"`) with `parent_id` pointing
to Lambda's auto-created segment.

```dart
await tracer.runLambda(traceId, parentId, functionName, fn, sampled: sampled);
```

**Critical:** trace context must come from the `Lambda-Runtime-Trace-Id`
**HTTP response header** (from `/invocation/next`), not from
`_X_AMZN_TRACE_ID` (env var). The env var carries the API Gateway trace ID;
the header carries the function-level trace ID Lambda's auto-segments use.
Using the env var produces orphaned subsegments in a separate trace.

### Zone-based context

`XRayTracer.run()` / `runLambda()` store four values in the Zone:
- `_zoneKey` → the active `Segment` (read by `currentSegment`, used for header injection)
- `_stateKey` → the `TraceState` (root scope + the pending-subsegment registry)
- `_currentScopeKey` → the current `TraceScope` (the root, or a `captureAsync` child)
- `_sampledKey` → `bool` sampling decision

Runtime trace data accumulates in a mutable `TraceScope` tree (`trace_scope.dart`);
the immutable `Segment` / `Subsegment` documents are produced when each scope
closes. `captureAsync(name, fn)` forks a child scope in a child `Zone`, so nested
and concurrent captures stay independent. Any code running inside `tracer.run(…)`
can read `tracer.currentSegment` without any explicit parameter threading.

### Undrained-response sweep

A subsegment opened by `beginSubsegment` (HTTP clients) closes when its response
body stream finishes. If a caller never drains the body, the close never fires —
so at finalization `TraceState.sweep()` closes any still-open span once, flags it
`metadata.xray.incomplete = true`, and attaches it to its parent. A `closedIds`
set keeps a late body-stream close after a sweep from double-attaching.

### Segment size limit

UDP datagrams are capped at 64 KB. `SegmentEncoder.encode()` splits
oversized segments into a skeleton segment + one independent subsegment
document per child subsegment.

---

## Key design decisions

| Decision | Rationale |
|---|---|
| **UDP-first** | Fire-and-forget; no ACK, no retry. PutTraceSegments HTTP API delivery is not shipped until SigV4 signing is implemented. |
| **Immutable models** | `Segment` / `Subsegment` are value objects; every mutation returns a copy. No shared-state races. |
| **Sampling at entry** | `shouldSample()` called once at `run()` entry; result stored in Zone and read by `closeSegment()` and every tracing path (HTTP clients, server middleware, Smithy interceptor) for header injection. Prevents orphaned child traces. |
| **Tracing never faults the app** | Sender / serialization failures during finalization are swallowed in `run` / `runLambda` / `closeSegment` / `close`. `UdpSender.onError` surfaces local failures without throwing. |
| **No `dart:mirrors`** | AOT-safe; compiles with `dart compile exe`. No `build_runner` step. Uses `dart:io`, so not Flutter-web compatible. |
| **`abstract class Sender`** | Not `abstract interface class`: a concrete `sendPackets()` default lives here so sub-classes don't break. |

---

## Trace ID format

```
1-{8-hex-epoch-seconds}-{24-hex-random}
e.g. 1-5759e988-bd862e3fe1be46a994272793
```

`TraceId.generate()` — creates new ID  
`TraceId.tryParse(header)` — parses `Root=…;Parent=…;Sampled=…`  
`TraceId.parseParentId(header)` — extracts `Parent=` field  
`TraceId.parseSampled(header)` — extracts `Sampled=` as `bool?`

---

## Smithy client wrappers

```dart
// 1. Register once at cold-start
XRay.registerClient<DynamoDbClient>(
  requestAdapter: (req) { ... return (operationName:, method:, url:, resource:); },
  responseAdapter: (res) => (
    statusCode:,
    contentLength:,
    requestId:,
    region:,
    errorCode:,
  ),
  // requestId -> aws.request_id; region -> aws.region; errorCode drives AWS
  // throttle detection for non-429 responses.
  rebuild: (client, wrapSend) {
    final inner = (req) => client.rawSend(req as DdbReq);
    return client.copyWith(httpSend: wrapSend(inner));
  },
);

// 2. Wrap per-instance
final ddb = XRay.fromClient(DynamoDbClient(...), tracer: tracer);
```

---

## AWS Lambda + `aws_lambda_dart_runtime_ns`

The recommended production integration uses `LambdaTraceCapture`:

```dart
// main.dart
final capture = LambdaTraceCapture();

void main() => capture.run(() => invokeAwsLambdaRuntime([
  xRayHandler(handleEvent), // your handler reads capture.context() -> runLambda
]));
```

`LambdaTraceCapture.run()` overrides the runtime's `package:http` client via
`http.runWithClient()` to capture `Lambda-Runtime-Trace-Id` per invocation.
Inside the handler, `capture.context()` returns the parsed `LambdaTraceContext`
(`traceId`, `parentId`, `sampled`), which you forward to `tracer.runLambda()`.
See the README "Lambda integration" section for the full handler wiring.

A fully deployable CDK example lives at `demos/lambda_dart_runtime/` in the
parent workspace (one level up from this package, not tracked in the SDK repo).

---

## CI / release

- **CI** (`ci.yml`): runs on every push/PR to `main`. Matrix: Dart stable + beta.
  `dart analyze --fatal-warnings` and `dart test` run on both; the format check
  and `dart pub publish --dry-run` run on stable only.
- **Commit lint** (`commitlint.yml`): validates PR titles as Conventional Commits.
- **Release** (`tag-release.yml`): the manual release button (Actions -> Run
  workflow on `main`; never fires on merges). Validates the pubspec version has
  a matching `## X.Y.Z` CHANGELOG section and no existing tag, pushes `vX.Y.Z`,
  then dispatches `publish.yml` on that tag (the `workflow_dispatch` API is
  exempt from the GITHUB_TOKEN no-recursive-triggers rule, and running on the
  tag ref is what pub.dev's OIDC exchange requires).
- **Publish** (`publish.yml`): runs on a `v*.*.*` tag (push or
  `workflow_dispatch` on the tag). Jobs run in order `test` (stable + beta) ->
  `github-release` (verify tag matches `pubspec.yaml`, create the Release from
  the matching `CHANGELOG.md` section) -> `publish` (Dart's reusable
  `dart-lang/setup-dart/.github/workflows/publish.yml@v1`, via OIDC, no stored
  token). Requires pub.dev automated publishing enabled for the repo with tag
  pattern `v{{version}}`.

**To release:** bump `pubspec.yaml`, add a matching `## X.Y.Z` section to
`CHANGELOG.md`, merge to `main`, then Actions -> **Release** -> Run workflow.
Everything from the tag to pub.dev runs automatically from there.

CLI fallback: `git tag -a vX.Y.Z -m "Release X.Y.Z" && git push origin vX.Y.Z`
— a locally pushed tag triggers `publish.yml` directly. To retry a failed
publish, dispatch **Publish to pub.dev** on the existing tag.

---

## Conventions

- Minimum SDK: `>=3.0.0 <4.0.0` (records and patterns required).
- Internal code lives under `lib/src/`; never import `src/` files directly.
- Public API controlled via `lib/aws_xray_sdk.dart` barrel export only.
- `dart analyze --fatal-warnings` must pass clean — enforced in CI.
- `pubspec.lock` is gitignored (library, not an app).
- One runtime dependency: `http` (for `XRayBaseClient`); otherwise only `dart:io` / `dart:convert` / `dart:async`.
- Releases are tagged manually on a commit that already contains `publish.yml`; CI never creates tags.

---

## Testing

`test/` mirrors `lib/src/` (26 test files). Common patterns when adding tests:

- **Assert on emitted output with `InMemorySender`.** Build the tracer with one,
  exercise the code, then inspect `sender.segments` (closed `Segment`s, the
  `run()` path) and `sender.packets` (raw UDP payloads, the `runLambda()` path).
  Prefer it over hand-rolled fake senders.
- **Restore global state in `tearDown`.** `XRay.configure` / `XRay.tracer` mutate
  the process-wide default and `XRay.patchHttp` installs global `HttpOverrides`.
  Tests that touch either must reset: `tearDown(XRay.reset)` and/or
  `tearDown(XRay.unpatchHttp)`, or they leak into the next test.
- **Decode a Lambda packet** by stripping the `{"format":"json","version":1}\n`
  header line and `jsonDecode`-ing the rest (see `tracer_lambda_test.dart`).
- **Deterministic timing.** `ReservoirSampler` takes an injectable `elapsedMicros`
  clock; pass a fake instead of sleeping. `nowSeconds()` (`utils.dart`) still reads
  the wall clock directly — timing-sensitive segment tests assert ordering, not
  absolute values.
- **No live sockets.** Use `NoopSender` / `InMemorySender`; never bind a real
  `UdpSender` in unit tests.
