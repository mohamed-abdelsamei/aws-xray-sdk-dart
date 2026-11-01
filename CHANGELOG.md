# Changelog

## 0.5.1

### Changed

- **Behaviour change — `aws.queue_url` and `aws.resource_names` are redacted
  like `http.request.url`.** The emitted document drops userinfo, query
  strings, and fragments from `aws.queue_url` and from every
  `aws.resource_names` entry (including URLs embedded in a longer entry), so
  an SQS queue URL carrying credentials or a signature no longer reaches
  X-Ray. Table and bucket names, ARNs, and plain queue URLs are unchanged. The
  in-memory `AwsData` keeps raw values. Accepted limit: a hand-built `AwsData`
  whose `resource_names` holds scheme-less credentials (`user:pw@host/path`)
  that differ from `queue_url` is not redacted; the built-in producers never
  create one.

### Fixed

- **Oversized single nodes are trimmed instead of sent whole.** A segment or
  subsegment too big on its own (for example a huge `metadata` value) could
  not be split, so it was sent as-is and the OS refused the datagram. The
  encoder now trims it to fit the 65507-byte datagram: the largest `metadata`
  values become the string `[truncated: N bytes]` (only as many as needed,
  and only when the marker is shorter) and `metadata.xray.truncated` is set to
  `true`; if that is not enough, the node is reduced to its ids, timing,
  flags, and `name` (capped at 200 UTF-16 code units); `http`, `aws`, `cause`
  and `user` data is dropped in that case. Nodes that already fit
  are byte-for-byte unchanged.
  **Behaviour change:** an emitted document can now differ from the recorded
  one, and a string can appear where a `metadata` map value used to be. The
  fix guarantees the packet fits the datagram, not that the X-Ray service
  accepts it. Ids passed directly to `runLambda` are not capped, so a huge id
  can still exceed the limit.

## 0.5.0

### Added

- **`errorStatus` hook for Smithy clients.** `XRay.registerClient` accepts an
  optional `errorStatus: int? Function(Object error)`. When it returns a status of 400
  or above for a thrown error, the subsegment is classified like a response
  (4xx error, 429 throttle, 5xx fault) and records `http.response.status`
  instead of always being a fault. Without the hook, behaviour is unchanged.

### Changed

The entries below change observable behaviour; review them before upgrading.

- **Behaviour change — recorded URLs no longer include query strings,
  userinfo, or fragments.** `http.request.url` is now
  `scheme://host[:port]/path` on every instrumentation path (`XRayHttpClient`,
  `XRayBaseClient`, `XRay.fromClient`, `handleTraced`, and user-built
  `HttpRequestData`), so presigned-URL signatures, OAuth codes, and `user:pw@`
  credentials stay out of X-Ray. There is no setting to keep the query string.
  The in-memory `HttpRequestData.url` keeps the raw value; only the emitted
  document is redacted. If a `?` or `#` comes before an `@`, that `@` may be
  part of a query: only a valid `host[:port]` before the `?` or `#` is kept.
- **Behaviour change — URLs inside exception messages are redacted too.**
  `cause.exceptions[].message` drops userinfo, query strings, and fragments
  from every URL it contains, so errors such as
  `ClientException: …, uri=https://…?X-Amz-Signature=…` no longer leak what
  `http.request.url` hides. This applies to caught errors, AWS error-body
  messages, and user-built `XRayException`s (in the emitted JSON; the
  in-memory `message` keeps its raw value). Redaction runs before the
  1024-character cap (see "Exception messages are capped" below). Anything
  from a `:` followed by `/` or `\` up to the next ASCII space or control
  character is treated as a URL. Not caught: URLs without a scheme, bare
  query strings, encoded URLs (`https:%2F%2Fu:p@h/p`, HTML or `\u` escapes),
  userinfo containing whitespace or control characters, userinfo containing a
  raw `/`, `?` or `#` when what precedes it looks like a host or host:port
  (`https://admin:2024/s3cret@h/p` reads as host, port and path), and
  secrets in the URL path.
- **Behaviour change — `Sender.sendPackets` now throws `UnsupportedError` by
  default.** It was a
  silent no-op, so a custom `Sender` that only overrode `send` lost every
  `runLambda` trace without notice. The error names the sender class; the
  tracer reports it through `onSendError` (when set) and never throws into
  the app. Direct callers of `sendPackets` on such a sender now receive the
  error. Custom senders used with `runLambda` must override `sendPackets`.
  `UdpSender`, `InMemorySender`, and `NoopSender` are unchanged.

### Fixed

- **`XRay.patchHttp` is idempotent.** Calling it twice nested two X-Ray
  layers, so every `dart:io` request was traced twice and one `unpatchHttp()`
  removed only one layer. A repeat call now replaces the X-Ray layer (using
  the new tracer) instead of wrapping it, and a single `unpatchHttp()`
  restores the overrides that were in place before the first patch.
- **Exception messages are capped and never throw.** `XRayException.from`
  truncates messages over 1024 UTF-16 code units and appends `…[truncated]`
  (without splitting a surrogate pair). If an error's `toString()` throws, the
  message falls back to its runtime type name; previously that dropped the
  whole segment when the error escaped `tracer.run`.
- **`onSendError` now fires for transport failures.** The `UdpSender` the
  tracer builds itself (no `sender` argument) swallowed resolve, bind, and
  datagram-send errors, so `onSendError` only ever saw encode errors. It now
  reports those local failures too, at most once per segment send, and never
  throws into the app. `runLambda` also reports a document that fails to
  encode (such as a cyclic metadata map) instead of dropping it silently. A
  user-supplied `UdpSender` keeps reporting through its own `onError`.
- **One refused datagram no longer silences tracing for good.** When the OS
  refuses a datagram (for example one over the datagram limit, or over 9216
  bytes on macOS's default UDP limit), Dart's socket returns 0 instead of
  throwing, and every later send on that socket did the same. `UdpSender`
  ignored this and kept the socket, so all later traces were lost with no
  error. A short send is now reported through `onError` (and the tracer's
  `onSendError`), and the socket is replaced so the next send gets through.
- **`handleTraced` flags failed requests.** The server segment recorded the
  response status but no flags, so a 500 looked healthy in X-Ray. A 4xx
  status now sets `error`, 429 sets `throttle` and `error`, and 5xx sets
  `fault`, matching client subsegments. The same applies to any segment
  closed by `run()` that carries an `http.response.status`.
  New: `Segment.applyStatus(int)`, the segment counterpart of
  `Subsegment.applyStatus`.
- **Large Lambda traces are no longer dropped.** `runLambda` sent the
  whole handler subsegment tree as a single UDP datagram, so a large
  invocation exceeded the datagram limit and the entire trace was lost.
  It now uses the same recursive split as standalone segments: the handler
  document is emitted without its children, and each child becomes its own
  subsegment document linked by `parent_id`. Small documents are unchanged,
  byte for byte.
- **Split threshold lowered to the real UDP limit.** The encoder split
  documents above 65536 bytes, but an IPv4 UDP datagram carries at most 65507,
  so documents of 65508 to 65536 bytes were sent as one datagram and failed.
  The cap is now 65507 bytes for both `encode()` and Lambda documents.
- **`AWS_XRAY_DAEMON_ADDRESS` parsing is stricter and broader.** `configure`
  now understands `[v6]:port`, bare IPv6 literals (`::1`), and the dual
  `tcp:h:p udp:h:p` form in either order (the `udp:` address is used).
  Malformed values (bad or out-of-range port, empty host, `tcp:`-only) fall
  back to `127.0.0.1:2000` instead of producing a half-parsed address.
- **Malformed incoming trace headers no longer leak into traces.**
  `TraceId.tryParse` (and so `TraceId.parseRootString`) now requires hex in
  the timestamp and random parts (non-hex ids were accepted and later failed
  an assert in debug builds).
  `handleTraced`, `tracer.trace()` and `LambdaTraceCapture.context()` drop
  `Parent` when the `Root` is invalid (a fresh trace is started) or the parent
  is not 16 hex characters.
- **One unencodable metadata value no longer drops the whole segment.** A
  `DateTime`, custom object, or `NaN`/`Infinity` in metadata made `jsonEncode`
  throw, so the segment was lost. Such values now fall back to `toJson()`, then
  `toString()`, then the placeholder `"<unencodable:Type>"`. Documents with only
  JSON-native values encode byte for byte as before.
- **A throwing Smithy adapter no longer breaks the AWS call.** In
  `XRay.fromClient` clients, a `requestAdapter` that throws now sends the call
  untraced. A `withTraceHeader` that throws sends the original request, still
  traced. A `responseAdapter` that throws after a successful call returns the
  response and closes the subsegment without response data. Only the
  transport's own error reaches the caller, as the same object with its
  original stack trace.
- **`XRayBaseClient` no longer faults AWS calls with odd request bodies.** A
  resource field of the wrong JSON type (for example `"TableName": 123`) threw
  a `TypeError` that replaced a 200 response, or the transport's own error.
  Such fields are now left out of the `aws` block. Tracing work after the
  response arrives is guarded, so a successful response always reaches the
  caller, and a transport error is rethrown unchanged.

## 0.4.1

Docs and release-tooling release — no library code changes.

- **One-button releases**: the "Release" workflow now auto-increments the
  version (patch/minor/major choice, patch by default) and generates a
  CHANGELOG section from commits when none is written, then tags and
  triggers the publish pipeline. A manual pubspec bump / hand-written
  section still wins. Releases are never created on merges to main.
- **Docs modernized to the `trace()` API**: README and examples now lead
  with `tracer.trace()` / `XRay.trace()`; `run()` is documented for its two
  remaining use cases (pre-built segments, `runLambdaInvocation` internals).
  Architecture and tracing-behavior docs updated to match, including the
  Lambda `Invoke` → `aws.function_name` capture and full-URL recording.

## 0.4.0

One-call tracing ergonomics: configure once, then trace any unit of work in a
single line — plus distributed-trace continuation and Lambda handler
polish. All changes are backward-compatible.

### Added

- **`XRayTracer.trace(name, fn)`** — the one-call entry point: creates the
  segment, runs `fn` inside the trace zone, closes, and sends. Accepts
  `FutureOr` so any function drops in, `user:` for the segment's user field,
  and `httpMethod:`/`urlPath:` for the sampling decision.
- **Distributed-trace continuation.** `trace(..., traceHeader:)` takes the
  incoming `X-Amzn-Trace-Id` header and links this service into the caller's
  trace (`Root=` becomes the trace id, `Parent=` the parent id); the local
  sampling strategy stays authoritative, matching `handleTraced`.
- **`XRay.trace(...)` and `XRay.capture(...)`** — static facades over the
  process-wide tracer, so after `XRay.configure()` the full trace lifecycle
  (root span, nested spans, annotations, metadata) needs no tracer threading.
  Both are safe no-ops before `configure()` runs.

### Changed

- `XRay.runLambdaInvocation` now accepts a `FutureOr`-returning `fn` (handler
  actions drop in without `() async =>` coercion) and an optional `tracer:`
  parameter to pin an instance instead of the global — consistent with the
  rest of the facade.
- Internal layout reorganized: zone-context machinery moved to
  `lib/src/context/`, the `X-Amzn-Trace-Id` formatter to `lib/src/models/`,
  and AWS partition-suffix knowledge consolidated in `lib/src/aws/region.dart`
  (`isAwsHost`). No public-API impact.
- Examples modernized to the `trace()`/`capture()` API, with a rewritten
  `advanced_tracing.dart` demonstrating `captureAsync` nesting and a stub-free
  look at what each example emits.

### Fixed

- `handleTraced` now records the **full request URL** (`requestedUri`) in the
  segment's `http.request.url` instead of only the path + query, per the X-Ray
  segment schema.
- The path-based custom-sampler demo in `example/sampling_strategies.dart`
  actually exercises the sampler now (it never forwarded `urlPath` into the
  sampling decision before) and prints each operation's sampled result.

## 0.3.1

### Added

- `package:http` AWS tracing now recognizes the Lambda data-plane `Invoke` call.
  `XRayBaseClient` reads the operation (`Invoke`) and target function from the
  REST path (`/2015-03-31/functions/{name}/invocations`), recording it as
  `aws.function_name` and adding the function to `aws.resource_names` so the
  invoked Lambda appears as its own node in the X-Ray service map.
- `AwsData.functionName`, serialized as `function_name` in the `aws` block per
  the X-Ray segment schema.

## 0.3.0

Stable release of the 0.3.0 line. Functionally identical to `0.3.0-beta.2` —
no API or behavior changes since the beta — with documentation and example
polish. For the full set of changes since `0.2.1`, see the `0.3.0-beta.1` and
`0.3.0-beta.2` sections below. Headline additions across the line:

- **Zero-config setup.** `XRay.configure()` builds a tracer from the AWS
  environment, installs a process-wide default (`XRay.tracer`), and patches HTTP
  in one idempotent call; `XRay.reset()` returns to the unconfigured no-op state.
- **`package:http` tracing.** `XRay.aws()` / `XRay.httpClientFor()` wrap an
  `http.Client` for `aws_client` / `aws_*_api` SDKs, resolving the global tracer
  per request.
- **Lambda ergonomics.** `LambdaTraceCapture` captures the
  `Lambda-Runtime-Trace-Id` header per invocation and `XRay.runLambdaInvocation`
  collapses the parent-decision branch into one call.
- **`InMemorySender`** for asserting on emitted segments and Lambda packets in
  tests, plus `XRayTracer.onSampledDrop` / `onSendError` diagnostics.

### Changed

- Examples and docs updated: the AWS SDK client example now prints the
  subsegments it produces (via `InMemorySender`), and the README/AGENT docs were
  corrected to match the shipped API surface.

## 0.3.0-beta.2

Second beta of the 0.3.0 line. This release tightens the beta.1 APIs and fixes
trace-fidelity edge cases found during integration testing.

### Added

- `InMemorySender`, exported from the package barrel, for tests that need to
  assert on emitted segments or Lambda packets without UDP or tracer mocks.
- `XRay.annotate(Map<String, Object>)` and `XRay.metadata(key, value)` facade
  helpers for adding data through the process-wide tracer.
- `TraceId.parseRootString(header)` for log-enrichment callers that only need
  the validated root trace id as a string.
- `XRayTracer.onSampledDrop` and `XRayTracer.onSendError` hooks to distinguish
  intentional sampled-out drops from send failures without faulting traced code.

### Changed

- `XRay.aws()` and `XRayBaseClient(inner)` now resolve the global tracer per
  request when no explicit tracer is passed. Clients created before
  `XRay.configure()` now trace after configuration.
- The unconfigured no-op tracer reports `isSampled == false` outside a trace
  zone, so it does not advertise `Sampled=1` for traces it will never emit.
- `contextMissingPolicy` is mutable on `XRayTracer` for runtime diagnostics and
  tests.
- `ReservoirSampler` now uses a monotonic `Stopwatch` clock instead of wall time,
  avoiding sampling-window resets from clock adjustments.
- Oversized segment encoding recursively splits large subsegment trees into
  independent subsegment documents where possible.
- Child subsegments are serialized in start-time order for clearer timelines when
  concurrent work closes out of order.

### Fixed

- AWS endpoint detection now covers standard, China, ISO, and ISO-B partitions,
  matching region extraction and preserving AWS metadata/error parsing outside
  `.amazonaws.com`.
- AWS query-protocol XML error parsing now handles namespace prefixes, tag
  attributes, CDATA, XML entities, malformed UTF-8, and out-of-range numeric
  entities without crashing the request path.
- `LambdaTraceCapture` stores captured runtime trace headers in a zone-local slot
  during `run()`, preventing interleaved invocations from reading each other's
  header.
- Unsampled `runLambda` invocations now skip subsegment serialization and notify
  `onSampledDrop` before any send/encoding work.
- Annotation key sanitization now emits a warn-once diagnostic when keys are
  changed, making lossy collisions visible.

## 0.3.0-beta.1

First beta of the 0.3.0 line. Themes: zero-config setup ergonomics, segment-level
HTTP recording for the server middleware, and a packaged Lambda trace-header
capture. Pre-release — published for integration testing.

### Added

- **Zero-config setup.** `XRay.configure({fromEnv, serviceName, sampling,
  tracer, patchDartIoHttp})` builds a tracer from the standard AWS environment
  (`AWS_XRAY_DAEMON_ADDRESS`, IPv6-literal safe; `AWS_LAMBDA_FUNCTION_NAME`),
  installs it as the process-wide default, and patches HTTP — in one idempotent
  call. `XRay.reset()` returns to the unconfigured state.
- **Global default tracer.** `XRay.tracer` getter/setter and `XRay.isConfigured`.
  Until configured, the default is a **no-op** that discards everything, so
  instrumentation runs unconditionally without null checks.
- **`XRay.aws({inner})`** and an optional-tracer **`XRay.httpClientFor`** return a
  pre-wrapped `package:http` client (using the global tracer) for
  `aws_client` / `aws_*_api` constructors.
- **`XRayBaseClient(inner)`** now accepts an optional tracer, defaulting to the
  global default tracer.
- **`XRay.runLambdaInvocation(capture, name, fn)`** runs one Lambda invocation,
  parenting under the `AWS::Lambda::Function` facade when a trace header was
  captured or starting a fresh segment otherwise.
- **`LambdaTraceCapture`** packages the `Lambda-Runtime-Trace-Id` capture
  (`http.runWithClient`-based) and exposes a parsed `LambdaTraceContext`
  (`traceId`, `parentId`, `sampled`) — no runtime fork needed.
- **`XRayTracer.annotateAll(Map)`** adds many annotations in one call.
- **`XRayTracer.currentTraceId`** convenience getter for the active trace id.
- **Segment HTTP data.** `Segment.http` (with `Segment.withHttp`); `handleTraced`
  now records the request (method, url, traced) and response (status,
  content_length) on the segment for the X-Ray service map, and forwards the
  request method/path into the sampling decision. `Segment.http` was removed in
  0.2.0 as structurally unusable; it is reintroduced now that the middleware
  populates it.

### Changed

- `handleTraced` reads the sampling decision **inside** the run zone, so an
  unsampled trace is correctly marked `Sampled=0` on the outgoing header
  (previously could fail open to `Sampled=1`).
- A handler that throws before setting a status no longer records a misleading
  `200`; the response block is omitted so the faulted segment stands alone.

### Documentation

- README: zero-config setup, the `aws_client` / `aws_*_api` recipe, and the
  `LambdaTraceCapture`-based Lambda example (replacing a hand-rolled shim).
- `doc/architecture.md`: updated for the new facade/tracer API surface.

## 0.2.1

### Documentation

- Consolidated the two overlapping HTTP sections in the README into one
  `HTTP tracing` section (`dart:io` patch, `package:http` client, response-body
  lifecycle), added a contents nav, and removed a duplicate daemon-setup section.
- Corrected the `AOT-safe` feature claim and dropped the misleading
  `Flutter safe` label — the package uses `dart:io` and is not Flutter-web
  compatible (matching `doc/tracing-behavior.md`).

## 0.2.0

First release since `0.1.0`. Contains **breaking changes** (allowed pre-1.0).
Major themes: nested/live tracing, `package:http` and server-side support,
automatic double-trace suppression, a hardened non-faulting transport, annotation
validation, and a dead-code cleanup.

### Breaking changes

- **Removed uninstrumented / dead API.** Each can be restored from git history
  once the matching instrumentation exists:
  - `SqlData` and `Subsegment.withSql` (no SQL instrumentation existed).
  - `HttpRequestData.userAgent`, `clientIp`, and `xForwardedFor` (never populated).
  - `Cause.workingDirectory` (never populated).
  - `Segment.service`, `Segment.http`, and `Segment.aws` (structurally always
    null — `Segment` exposed no way to set them).
  - The unused helpers `namespaceForClient` and `namespaceFor<T>`.
- **`HttpApiSender` was removed** — SigV4 signing is not yet implemented; use
  `UdpSender` (the default) for all deployments.
- **The stale `awsServiceNamespaces` map was removed** — Smithy client
  registration now defaults directly to the valid X-Ray namespace `aws`.
- **Registry internals are no longer exported** from the package barrel. Use
  `XRay.registerClient` / `XRay.fromClient`; direct access to `clientRegistry`,
  `descriptorFor`, and `ClientDescriptor` was an implementation detail.
- **Annotation values are now sanitized.** `annotate` keeps the same signature
  but no longer stores arbitrary keys/values verbatim (see *Annotation
  validation* below) — a caller relying on invalid keys/values reaching X-Ray
  unchanged will see different output.
- **`SmithyResponseAdapter` now returns AWS response metadata.** Adapter records
  must include nullable `requestId`, `region`, and `errorCode` fields in addition
  to `statusCode` and `contentLength`. This lets `XRay.fromClient` populate
  `aws.request_id`, `aws.region`, and AWS throttling flags.

### New features

**Nested & live tracing**
- `XRayTracer.captureAsync(name, fn)` runs a block as a **nested** subsegment.
  Manual subsegments and auto-instrumented HTTP/AWS calls opened inside it become
  its children, so traces reflect the real call tree (previously all subsegments
  were flat siblings). Each scope is bound to a forked `Zone`, so concurrent
  captures stay independent.
- `XRayTracer.annotate(key, value)` / `addMetadata(key, value)` mutate the entity
  currently being traced (the active `captureAsync` subsegment, or the segment
  itself). Previously annotations could only be set at `Segment.begin` time.
- `TraceContext` — the live handle passed to a `captureAsync` block
  (`annotate` / `addMetadata` / `setError` / `setFault`).
- An uncaught error from `run` / `runLambda` / `captureAsync` now marks the
  enclosing entity as faulted with a cause.

**`package:http` and server-side tracing**
- `XRayBaseClient` wraps a `package:http` `BaseClient`, tracing each request with
  the same subsegment + AWS metadata extraction as the `dart:io` path.
- HTTP instrumentation now sets `http.request.traced = true` when the SDK injects
  `X-Amzn-Trace-Id`, allowing downstream service-to-service linkage in X-Ray.
- `handleTraced(request, tracer, handler)` — `dart:io` `HttpServer` middleware
  that continues an incoming `X-Amzn-Trace-Id`, runs the handler in a trace zone,
  and injects the trace header into the response for downstream propagation.
- `XRay.untracedHttpClient()` builds an `HttpClient` that is never wrapped by
  `patchHttp`, for calls that should emit no subsegment.

**Automatic double-trace suppression**
- `XRayBaseClient` and `XRay.fromClient` run their inner send inside
  `runWithoutDartIoTracing` (a zone flag); `XRayHttpClient` stands down when it is
  set. A request passing through both a wrapper and a `patchHttp`-patched
  `dart:io` client is now traced exactly once.
- Smithy client namespaces are normalized to X-Ray schema values (`aws` or
  `remote`) so custom or `AWS::...` registration values cannot produce invalid
  subsegment namespaces.

**AWS trace fidelity**
- Smithy client wrappers record `aws.request_id` when the response adapter
  supplies it and record `aws.region` from the adapter or request URL.
- AWS throttles are detected from known AWS error codes such as
  `ProvisionedThroughputExceededException`, `ThrottlingException`,
  `RequestLimitExceeded`, `TooManyRequestsException`, and `SlowDown`, not only
  from HTTP `429`.
- Error-status responses that do not throw now synthesize a remote HTTP `cause`
  so 4xx/5xx subsegments have diagnostic detail.

**Transport & sampling**
- `UdpSender` gained an optional `onError(Object)` callback (silent by default)
  and a re-openable `close()`; it resolves + binds once (memoized), uses an
  IP-literal fast path, and contains all resolution/bind/send errors.
- `XRayTracer` gained `daemonHost` / `daemonPort` constructor parameters and a
  `contextMissingPolicy` (`ContextMissingPolicy.ignore` / `logError` /
  `runtimeError`) controlling what happens when trace data is recorded with no
  active trace zone.
- `ReservoirSampler` accepts an injectable `now` clock (`DateTime Function()`)
  for deterministic tests.

**Annotation validation (X-Ray best practices)**
- Annotation keys and values are validated at every entry point
  (`XRayTracer.annotate`, the `TraceContext` handle, `Segment.annotate`,
  `Subsegment.annotate`) by **sanitizing**, never throwing: invalid key
  characters (outside `[A-Za-z0-9_]`) become `_`, and a non-scalar value (not
  `String`/`bool`/`int`/`double`) is coerced to its `toString()`. A malformed
  annotation never drops the trace or faults the traced operation. Metadata
  remains unvalidated (any JSON-serializable value) by design.

### Fixes

- **Non-faulting transport guarantee.** A `Sender` (or scope-serialization)
  failure during finalization can no longer fault or mask the traced operation —
  `run` / `runLambda` / `closeSegment` / `close()` contain transport errors for
  any `Sender`, not just `UdpSender`. Fixes a throw in the finalization `finally`
  superseding `fn`'s return value or original exception.
- **`UdpSender` could fault the traced operation.** Removed a per-send DNS
  `lookup` + `bind`, a socket-bind race under concurrency, and unguarded
  `lookup`/`bind` errors escaping into the awaited `run()`.
- **`XRayHttpClient` double-recorded a subsegment** when a response body stream
  errored then completed (consumed with `cancelOnError: false`). The fault path
  and the done path are now mutually exclusive.
- **Undrained HTTP responses no longer drop spans.** If an instrumented
  `dart:io` or `package:http` response body is never consumed, trace finalization
  emits the subsegment once with `metadata.xray.incomplete = true` and the
  request/response data known so far.
- **Manual subsegment close is idempotent.** Re-closing a subsegment, including a
  late close after an incomplete-response sweep, records the first outcome once.
- **`handleTraced` reported the wrong `Sampled=` flag.** The response header's
  sampling flag was read after the trace zone closed (fail-open `true`), so it
  always emitted `Sampled=1`; it now reports the real decision.
- `Segment.withFault(err)` / `Segment.withError(err)` record exceptions directly
  on segments (previously only `Subsegment` supported this).
- `Segment.close()` is idempotent — calling it on an already-closed segment
  preserves the original timing.
- `XRayHttpClient` preserves the request scheme for host/port overloads
  (`get`/`post`/`open` use `http`, not an unconditional `https`) and closes the
  traced subsegment on `detachSocket()` raw-socket upgrades.
- Removed debug `stderr.writeln` logging from `runLambda` and per-packet
  `dart:developer` logging from `UdpSender`.

### Internal & architecture

- Runtime trace state is a mutable `TraceScope` entity tree (internal),
  serialized to the immutable `Segment` / `Subsegment` documents at scope close;
  `Subsegment.open(...)` materializes an accumulated scope.
- `runLambda` emits its handler span via the subsegment model (consistent
  `nowSeconds()` timing, nested children, fault capture) instead of a hand-built
  document.
- Extracted `_runZoned` in `tracer.dart` (shared by `run`/`runLambda`); reused
  `encodeSubsegmentDoc` in the encoder's oversize-split path; removed the
  unimplemented HTTP API sender stub; de-duplicated HTTP metadata, AWS region,
  throttle-code, and trace-header helpers.

### Documentation & tests

- Documented X-Ray annotation/metadata constraints, the `ContextMissingPolicy`
  options, local sampler semantics + no-centralized-fallback behavior, the
  double-trace suppression model, and the Lambda subsegment contract (README +
  `doc/architecture.md`).
- Documented the HTTP tracing lifecycle, including incomplete spans for
  undrained responses and the single-use request expectation for
  `XRayBaseClient`.
- Added a `Segment` / `Subsegment` JSON golden test and broad coverage for the
  HTTP clients, `runLambda`, transport containment, `UdpSender` robustness,
  annotation validation, `handleTraced`, and the resource extractors.

## 0.1.0

Initial release.

### Core tracing
- `XRayTracer` with Zone-based context propagation (`run`, `runLambda`)
- Immutable `Segment` and `Subsegment` value objects with annotation and metadata support
- `TraceId` generation and parsing (`Root` / `Parent` / `Sampled` header fields)
- `FixedRateSampler` and `ReservoirSampler`

### Transport
- `UdpSender` — fire-and-forget UDP to the X-Ray daemon (IPv4 / IPv6, 64 KB split)
- `encodeSubsegmentDoc` — encode an independent subsegment document for Lambda
- `NoopSender` for tests and local development

### HTTP instrumentation
- `XRayHttpClient` wraps `dart:io` `HttpClient`; auto-traces every request
- `XRay.patchHttp` / `XRay.unpatchHttp` for global `dart:io` patching
- Automatic `namespace='aws'` for `*.amazonaws.com` hosts

### AWS SDK wrappers
- `XRay.registerClient<T>` / `XRay.fromClient<T>` for Smithy-generated clients
- `ResourceExtractor` built-ins for DynamoDB, S3, KMS, SQS, and SNS

### Lambda support
- `XRayTracer.runLambda` emits a subsegment document parented to the
  auto-created `AWS::Lambda::Function` segment instead of a competing
  top-level segment
- `AWS_XRAY_DAEMON_ADDRESS` env-var parsing for link-local daemon address
