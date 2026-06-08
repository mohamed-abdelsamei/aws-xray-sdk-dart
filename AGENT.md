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
    tracer.dart              # XRayTracer — Zone context, run(), runLambda(), sampling gate
    xray.dart                # XRay facade — patchHttp(), fromClient<T>(), registerClient()
    utils.dart               # randomHex(), nowSeconds()
    models/
      segment.dart           # Segment (immutable value object)
      subsegment.dart        # Subsegment (immutable value object)
      trace_id.dart          # TraceId — generate, tryParse, parseParentId, parseSampled
      cause.dart             # Cause + XRayException
      http_data.dart         # HttpData, HttpRequestData, HttpResponseData
      aws_data.dart          # AwsData — operation, tableName, bucketName, …
    sampling/
      sampling_strategy.dart # SamplingRequest, SamplingStrategy interface
      fixed_rate_sampler.dart
      reservoir_sampler.dart
    sender/
      sender.dart            # Sender abstract class (send, close, sendPackets)
      udp_sender.dart        # UdpSender — fire-and-forget UDP, IPv4/IPv6 aware
      noop_sender.dart       # NoopSender — discards all (tests / local dev)
      http_api_sender.dart   # HttpApiSender — stub; send() throws UnimplementedError
      segment_encoder.dart   # encode() — 64 KB split logic
    http/
      xray_http_client.dart  # XRayHttpClient — wraps dart:io HttpClient
      xray_http_overrides.dart # global dart:io patch
    wrappers/
      xray_interceptor.dart  # XRayInterceptor<Req,Res>, buildTraceHeader()
      client_registry.dart   # ClientDescriptor, clientRegistry, XRayWrapFn
      resource_extractor.dart# ResourceExtractor — DDB/S3/KMS/SQS/SNS
      aws_service_names.dart # client type → X-Ray namespace string
test/                        # mirrors lib/src/ structure
example/                     # pub.dev examples (9 files + README.md)
scripts/
  run-daemon.sh              # start X-Ray daemon via Docker with SSO creds
.github/
  workflows/
    ci.yml                   # push/PR: format + analyze + test (stable + beta)
    release.yml              # tag v*.*.*: verify version, GitHub Release, pub publish
```

---

## Architecture

### Data flow — standalone

1. `tracer.run(segment, fn)` makes the sampling decision **once**, stores
   `Segment` and `bool sampled` in a Dart `Zone`.
2. Inside `fn`, HTTP calls go through `XRayHttpClient` (auto via
   `XRay.patchHttp`) or `XRayInterceptor` (Smithy clients via
   `XRay.fromClient<T>()`). Each opens a subsegment, injects
   `X-Amzn-Trace-Id`, awaits, then closes the subsegment.
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

`XRayTracer.run()` stores two values in the Zone:
- `_segmentKey` → the active `Segment` (mutable via `addSubsegment`, etc.)
- `_sampledKey` → `bool` sampling decision

Any code running inside `tracer.run(…)` can read `tracer.currentSegment`
without any explicit parameter threading.

### Segment size limit

UDP datagrams are capped at 64 KB. `SegmentEncoder.encode()` splits
oversized segments into a skeleton segment + one independent subsegment
document per child subsegment.

---

## Key design decisions

| Decision | Rationale |
|---|---|
| **UDP-first** | Fire-and-forget; no ACK, no retry. `HttpApiSender` is a stub (SigV4 not implemented) — never use in production. |
| **Immutable models** | `Segment` / `Subsegment` are value objects; every mutation returns a copy. No shared-state races. |
| **Sampling at entry** | `shouldSample()` called once at `run()` entry; result stored in Zone and read by `closeSegment()` and both interceptors. Prevents orphaned child traces. |
| **No `dart:mirrors`** | AOT / Flutter safe. No `build_runner` step. |
| **`abstract class Sender`** | Not `abstract interface class` — concrete `sendPackets()` default lives here so sub-classes don't break. |

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
  responseAdapter: (res) => (statusCode:, contentLength:),
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

The recommended production integration:

```dart
// main.dart
await invokeWithXRay(() => invokeAwsLambdaRuntime([
  xRayHandler(name: 'fn.handler', tracer: tracer, action: handleEvent),
]));
```

`invokeWithXRay` wraps the runtime's `package:http` calls via
`http.runWithClient()` to capture `Lambda-Runtime-Trace-Id` per invocation.
`xRayHandler` reads that captured header and calls `tracer.runLambda()`.

See `demos/lambda_dart_runtime/` for a fully deployable CDK example.

---

## CI / release

- **CI** (`ci.yml`): runs on every push/PR to `main`. Matrix: Dart stable + beta.
  Steps: format check → `dart analyze --fatal-warnings` → `dart test`.
- **Release** (`release.yml`): triggers on `v*.*.*` tags.
  Verifies tag matches `pubspec.yaml` version, creates a GitHub Release from
  `CHANGELOG.md`, then runs `dart pub publish --force` via OIDC
  (no stored token — requires pub.dev automated publishing setup).

To release:
```bash
git tag v0.1.0
git push origin v0.1.0
```

---

## Conventions

- Minimum SDK: `>=3.0.0 <4.0.0` (records and patterns required).
- Internal code lives under `lib/src/`; never import `src/` files directly.
- Public API controlled via `lib/aws_xray_sdk.dart` barrel export only.
- `dart analyze --fatal-warnings` must pass clean — enforced in CI.
- `pubspec.lock` is gitignored (library, not an app).
- No runtime dependencies; everything is in `dart:io` / `dart:convert` / `dart:async`.
