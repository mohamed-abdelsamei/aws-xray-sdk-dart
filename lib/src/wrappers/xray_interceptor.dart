import '../models/aws_data.dart';
import '../trace_suppression.dart';
import '../tracer.dart';
import 'resource_extractor.dart';

/// Intercepts a Smithy HTTP send call to open/close an X-Ray subsegment.
///
/// Usage: wrap the client's HTTP send function with [XRayInterceptor.wrap].
///
/// This class is intentionally decoupled from the Smithy types so it can be
/// tested without an aws_sdk_dart dependency. The [SendFn] typedef abstracts
/// the underlying transport.
typedef SendFn<Req, Res> = Future<Res> Function(Req request);

/// Extracts tracing metadata from a typed Smithy request.
typedef SmithyRequestAdapter<Req> = ({
  String operationName,
  String method,
  String url,
  Map<String, Object?> body,
  Req Function(Req original, String traceHeader) withTraceHeader,
});

/// Extracts status code from a typed Smithy response.
typedef SmithyResponseAdapter<Res> = ({
  int statusCode,
  int? contentLength,
});

/// Wraps a Smithy [SendFn] with X-Ray tracing.
final class XRayInterceptor<Req, Res> {
  const XRayInterceptor({
    required XRayTracer tracer,
    required String namespace,
    required ResourceExtractor extractor,
    required SmithyRequestAdapter<Req> Function(Req) requestAdapter,
    required SmithyResponseAdapter<Res> Function(Res) responseAdapter,
  })  : _tracer = tracer,
        _namespace = namespace,
        _extractor = extractor,
        _requestAdapter = requestAdapter,
        _responseAdapter = responseAdapter;

  final XRayTracer _tracer;
  final String _namespace;
  final ResourceExtractor _extractor;
  final SmithyRequestAdapter<Req> Function(Req) _requestAdapter;
  final SmithyResponseAdapter<Res> Function(Res) _responseAdapter;

  /// Returns a new send function that wraps [inner] with tracing.
  SendFn<Req, Res> wrap(SendFn<Req, Res> inner) => (request) async {
        final segment = _tracer.currentSegment;
        if (segment == null) return inner(request);

        final adapted = _requestAdapter(request);
        var sub = _tracer.beginSubsegment(
          adapted.operationName,
          namespace: _namespace,
        );

        // Inject trace header using the sampling decision stored in the zone.
        final traceHeader = buildTraceHeader(
          traceId: segment.traceId.toString(),
          segmentId: sub.id,
          sampled: _tracer.isSampled,
        );
        final tracedRequest = adapted.withTraceHeader(request, traceHeader);

        AwsData awsData;
        try {
          awsData = _extractor(adapted.operationName, adapted.body);
        } catch (_) {
          awsData = AwsData(operation: adapted.operationName);
        }

        try {
          // Suppress the global dart:io patch for the inner send so a patched
          // HttpClient underneath the Smithy transport does not trace this same
          // request again as a bare host-named subsegment.
          final response =
              await runWithoutDartIoTracing(() => inner(tracedRequest));
          final resAdapted = _responseAdapter(response);

          sub = sub
              .withHttpCall(
                method: adapted.method,
                url: adapted.url,
                status: resAdapted.statusCode,
                contentLength: resAdapted.contentLength,
              )
              .withAws(awsData);

          _tracer.endSubsegment(sub);
          return response;
        } catch (e) {
          _tracer.failSubsegment(sub.withAws(awsData), e);
          rethrow;
        }
      };
}

/// Builds the `X-Amzn-Trace-Id` header value.
///
/// [traceId] is the string form of the root trace ID (`1-xxxx-xxxx`).
String buildTraceHeader({
  required String traceId,
  required String segmentId,
  required bool sampled,
}) =>
    'Root=$traceId;Parent=$segmentId;Sampled=${sampled ? 1 : 0}';
