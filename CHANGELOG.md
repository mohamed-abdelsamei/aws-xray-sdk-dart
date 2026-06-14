# Changelog

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
