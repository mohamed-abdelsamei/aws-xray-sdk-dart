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
    diagnostic.dart          # XRayDiagnostic, onDiagnostic delivery (deliverDiagnostic, safeNotify)
    utils.dart               # randomHex(), nowSeconds(), truncateMessage() (1024-char cap)
    context/
      trace_scope.dart       # TraceScope / TraceContext — live mutable entity tree, serialized at close
      trace_suppression.dart # runWithoutDartIoTracing() — prevents double-tracing under patchHttp
    models/
      segment.dart           # Segment (immutable value object)
      subsegment.dart        # Subsegment (immutable value object)
      trace_id.dart          # TraceId — generate, tryParse, parseParentId, parseSampled
      trace_header.dart      # buildTraceHeader(), validParentId() — header build + hex validation
      cause.dart             # Cause + XRayException
      http_data.dart         # HttpData, HttpRequestData, HttpResponseData, redactUrl()
      aws_data.dart          # AwsData — operation, tableName, bucketName, …
      annotation.dart        # annotation key/value sanitize + coerce helpers
    sampling/
      sampling_strategy.dart # SamplingRequest, SamplingStrategy interface
      fixed_rate_sampler.dart
      reservoir_sampler.dart  # injectable clock for deterministic tests
    sender/
      sender.dart            # Sender abstract class (send, close, sendPackets — default throws)
      udp_sender.dart        # UdpSender — fire-and-forget UDP, resolve/bind once, onError hook
      daemon_address.dart    # parseDaemonAddress() — AWS_XRAY_DAEMON_ADDRESS, all formats
      daemon_address_warning.dart # warnIfDaemonAddressInvalid() — one-time malformed-address report
      noop_sender.dart       # NoopSender — discards all (local dev)
      in_memory_sender.dart  # InMemorySender — records segments + packets for test assertions
      segment_encoder.dart   # encode(), encodeSubsegmentDocs() — 65507-byte split logic
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
    tag-release.yml          # "Release" button: release PR for the bump, then tag vX.Y.Z + dispatch publish
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

A UDP datagram over IPv4 carries at most **65507 bytes** (65535 − 8 UDP header
− 20 IP header). `encode()` splits an oversized segment into a skeleton segment
plus independent subsegment documents, recursing into nested children; the
Lambda path (`encodeSubsegmentDocs()`) splits the same way. A single node that is
over the cap on its own is trimmed to fit (largest metadata values replaced by a
`[truncated: N bytes]` marker, then a bare node as a last resort); nodes that
fit are unchanged.

### Redaction at serialization

The in-memory models keep raw values; redaction happens when JSON is emitted,
at one choke point per field, never per call site:

- `HttpRequestData.toJson()` passes every URL through `redactUrl()`
  (`http_data.dart`): userinfo, query string and fragment are stripped, leaving
  `scheme://host[:port]/path`. Not configurable.
- `XRayException.from()` guards `toString()` (a throwing `toString()` falls
  back to the type name), then strips every URL inside the message with
  `redactUrlsInText()` (`http_data.dart`), then caps it at 1024 UTF-16 code
  units plus `…[truncated]` via `truncateMessage()`. Redaction must precede
  the cap, or a URL cut inside its userinfo leaks part of the password. AWS
  error-body messages in `XRayBaseClient` take the same path, and
  `XRayException.toJson()` redacts again (idempotent, no cap) so user-built
  exceptions are covered. Known gaps are listed in `doc/tracing-behavior.md`.

When changing a sanitizer, test it with hostile input (separators inside the
secret, backslashes, leading whitespace/control characters), not just
well-formed URLs.

---

## Key design decisions

| Decision | Rationale |
|---|---|
| **UDP-first** | Fire-and-forget; no ACK, no retry. PutTraceSegments HTTP API delivery is not shipped until SigV4 signing is implemented. |
| **Immutable models** | `Segment` / `Subsegment` are value objects; every mutation returns a copy. No shared-state races. |
| **Sampling at entry** | `shouldSample()` called once at `run()` entry; result stored in Zone and read by `closeSegment()` and every tracing path (HTTP clients, server middleware, Smithy interceptor) for header injection. Prevents orphaned child traces. |
| **Tracing never faults the app** | User adapters, `toString()`, `toJson()` and the sender are all guarded; a failure in instrumentation never replaces the app's result or exception (the original error is rethrown unchanged). Sender / encode failures during finalization are contained and reported to `XRayTracer(onSendError:)` — including transport errors from the tracer-built `UdpSender` and `runLambda` encode failures. Contained user-adapter failures, trimmed nodes and a malformed daemon address go to the optional `onDiagnostic` hook; send failures stay on `onSendError`. `onSendError`, `onSampledDrop` and `onDiagnostic` all run through `safeNotify`, which swallows sync throws and the late failure of an async hook. |
| **No `dart:mirrors`** | AOT-safe; compiles with `dart compile exe`. No `build_runner` step. Uses `dart:io`, so not Flutter-web compatible. |
| **`abstract class Sender`** | Not `abstract interface class`: `sendPackets()` has a concrete default so sub-classes compile, but it throws `UnsupportedError` — a custom sender used with `runLambda()` must override it. The tracer reports the failure via `onSendError`. `NoopSender`, `InMemorySender`, `UdpSender` override it. |
| **Untrusted trace headers** | Incoming `X-Amzn-Trace-Id` values are validated (hex IDs, `validParentId()`); a malformed header starts a fresh trace instead of linking to a bogus parent. |
| **Test seams hidden** | Internal helpers that tests import directly (`redactUrl`, `redactUrlsInText`, `newTracerWithUdpSeamsForTesting`, `createDiagnostic`) are excluded with `hide` in the barrel. Keep new seams out of the public API the same way. The encoder reports trims through a zone value (`trimReportKey` in `segment_encoder.dart`) that the tracer sets around each send; keep the key and its callback signature in sync on both sides. |

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
`validParentId(header)` (`trace_header.dart`) — `Parent=` only when it and `Root` are valid hex, else `null`

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
  workflow on `main`; never fires on merges). Resolves the version — an
  unreleased pubspec version is used as-is; an already-tagged one is
  auto-incremented by the chosen bump level (patch default) and written back.
  Generates a `## X.Y.Z` CHANGELOG section from commit subjects when none is
  hand-written. If pubspec/CHANGELOG changed, it commits them as
  `chore(release): X.Y.Z` on a `release/vX.Y.Z` branch through the GraphQL
  `createCommitOnBranch` API (so GitHub signs the commit), opens a PR, and
  stops. Once that PR is merged, a second run finds nothing to change, pushes
  `vX.Y.Z`, and dispatches `publish.yml` on that tag (the `workflow_dispatch`
  API is exempt from the GITHUB_TOKEN no-recursive-triggers rule, and running
  on the tag ref is what pub.dev's OIDC exchange requires). CI does not run on
  the release PR, because GITHUB_TOKEN-made events trigger no workflows.
- **Publish** (`publish.yml`): runs on a `v*.*.*` tag (push or
  `workflow_dispatch` on the tag). Jobs run in order `test` (stable + beta) ->
  `github-release` (verify tag matches `pubspec.yaml`, create the Release from
  the matching `CHANGELOG.md` section) -> `publish` (Dart's reusable
  `dart-lang/setup-dart/.github/workflows/publish.yml@v1`, via OIDC, no stored
  token). Requires pub.dev automated publishing enabled for the repo with tag
  pattern `v{{version}}`.
- **Branch protection** (repository rulesets, no bypass actors): "Signed
  commits" requires verified signatures on every branch; "Protect main" requires
  a pull request (0 approvals) and blocks force-push and deletion on `main`.
  Nobody, including the owner and the Release workflow, pushes to `main`
  directly. Personal-account repos cannot give the GitHub Actions app a bypass,
  which is why the Release workflow goes through a PR.

**To release:** Actions -> **Release** -> Run workflow, picking the bump
level (patch/minor/major). It opens a `chore(release): X.Y.Z` PR; merge it
(squash or merge commit), then run **Release** again. The second run tags,
creates the GitHub Release and publishes to pub.dev. For curated
release notes or a pre-release version (e.g. `0.5.0-beta.1`), bump
`pubspec.yaml` and/or write the `## X.Y.Z` section by hand, merge to `main`
first, and the workflow uses them as-is and tags on the first run.

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
- Release tags come only from the manual **Release** workflow (or a hand-pushed `git tag`); nothing tags or publishes on merges to `main`.
- PR titles and commits are Conventional Commits with a **lowercase subject** (enforced by `commitlint.yml`); use `fix!:` / `feat!:` only for breaking API or contract changes (behaviour changes that are not breaking get a plain `fix:`/`feat:` and a CHANGELOG note).
- `feat` / `fix` / `perf` / breaking changes get a `CHANGELOG.md` entry under a `## X.Y.Z` heading — never `## Unreleased`, which the release workflow does not recognise.
- Don't bump `pubspec.yaml`'s version; the Release workflow does it.
- Keep the docs and examples in step with the code. When a change alters public API, observable behaviour, a default, or a documented limit, update in the same PR: the matching sections of `README.md` and `doc/` (behaviour contracts, limits, package layout), the dartdoc on the changed API, and `example/` (edit an example that the change makes wrong; add a runnable one, listed in `example/README.md`, for a new public feature). Run any example you add or change. If a change needs none of this, say so in the PR description. Don't document internal-only changes.

---

## Testing

`test/` mirrors `lib/src/`. Common patterns when adding tests:

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
