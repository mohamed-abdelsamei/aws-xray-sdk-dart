/// AWS X-Ray tracing client for Dart.
///
/// Typical usage:
/// ```dart
/// import 'package:aws_xray_sdk/aws_xray_sdk.dart';
///
/// final tracer = XRayTracer(serviceName: 'my-service');
///
/// // Instrument a Smithy AWS SDK client once at startup.
/// final ddb = XRay.fromClient(DynamoDbClient(...), tracer: tracer);
///
/// // Optionally trace all dart:io HTTP calls.
/// XRay.patchHttp(tracer);
///
/// // Run a traced operation.
/// final segment = Segment.begin(name: 'my-service', traceId: TraceId.generate());
/// await tracer.run(segment, () async {
///   final result = await ddb.getItem(...);
/// });
/// ```
library;

// Core
export 'src/tracer.dart';
export 'src/xray.dart';

// Models
export 'src/models/trace_id.dart';
export 'src/models/segment.dart';
export 'src/models/subsegment.dart';
export 'src/models/http_data.dart';
export 'src/models/aws_data.dart';
export 'src/models/cause.dart';

// Sender
export 'src/sender/sender.dart';
export 'src/sender/udp_sender.dart';
export 'src/sender/noop_sender.dart';

// Sampling
export 'src/sampling/sampling_strategy.dart';
export 'src/sampling/fixed_rate_sampler.dart';
export 'src/sampling/reservoir_sampler.dart';

// Wrappers (client registry + interceptor)
export 'src/wrappers/client_registry.dart' show XRayWrapFn;
export 'src/wrappers/resource_extractor.dart' show ResourceExtractor;
export 'src/wrappers/xray_interceptor.dart'
    show SmithyRequestAdapter, SmithyResponseAdapter;

// HTTP patch
export 'src/http/xray_http_client.dart';

// HTTP client (package:http)
export 'src/http/xray_base_client.dart';

// Server middleware
export 'src/http/xray_server_middleware.dart';

// Lambda trace-header capture
export 'src/lambda/lambda_trace_capture.dart';
