# Changelog

## 0.2.0

### Review-driven improvements

**New features & fixes:**
- `Segment.withFault(Object? err)` / `Segment.withError(Object? err)` — record
  exceptions and errors directly on segments (previously only `Subsegment`
  supported this)
- `Segment.aws` is now typed as `AwsData?` instead of raw `Map<String, Object>?`
  (consistent with `Subsegment`)
- `Segment.close()` is now idempotent — calling it on an already-closed segment
  preserves the original timing
- `HttpApiSender` removed from the barrel export until SigV4 is implemented
- Debug `stderr.writeln` logging removed from `runLambda`

**Architecture simplifications:**
- Extracted `_runZoned` helper in `tracer.dart` — eliminates zone-scaffolding
  duplication between `run()` and `runLambda()` (~30 lines saved)
- Reused `encodeSubsegmentDoc` in the encoder's oversize-segment split path

**Expanded test coverage:**
- `test/http/xray_http_client_test.dart` — 336 lines covering header injection,
  status recording, error/fault propagation, connection failures, namespacing,
  and pass-through when no segment is active (was previously untested)
- `test/tracer_lambda_test.dart` — 188 lines covering packet delivery, document
  shape, zone context, and subsegment embedding in `runLambda` (was previously
  untested)
- `test/models/sql_data_test.dart`, `aws_data_test.dart`, `http_data_test.dart`,
  `cause_test.dart` — model serialisation tests for the remaining data classes

**Documentation:**
- Added "Recording errors on the segment itself" example in README
- Added Roadmap section documenting known stubs and planned features
- `ReservoirSampler` doc now notes isolate-safety requirements

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
- `HttpApiSender` stub (pending SigV4 signing)

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
