import 'dart:io';

import '../models/http_data.dart';
import '../models/segment.dart';
import '../models/trace_id.dart';
import '../trace_header.dart';
import '../tracer.dart';

/// Extracts X-Ray trace context from an incoming HTTP request's
/// `X-Amzn-Trace-Id` header and runs [handler] inside [tracer.run].
///
/// If the header carries a `Parent=` (segment ID from the upstream service),
/// it is set on the segment so the X-Ray service map correctly links this
/// service as a downstream node.
///
/// The request method and path are forwarded into the sampling decision (so
/// path/method-based rules can match), and the request (method, url) and
/// response (status, content length) are recorded on the segment's `http`
/// block for the service map.
///
/// Usage with `dart:io` [HttpServer]:
/// ```dart
/// server.listen((request) async {
///   await handleTraced(request, tracer, () => handleRequest(request));
/// });
/// ```
Future<T> handleTraced<T>(
  HttpRequest request,
  XRayTracer tracer,
  Future<T> Function() handler, {
  String? serviceName,
}) async {
  final upstreamHeader = request.headers.value('x-amzn-trace-id') ?? '';
  final upstreamTraceId = TraceId.tryParse(upstreamHeader);
  final parentId = TraceId.parseParentId(upstreamHeader);

  final segment = Segment.begin(
    name: serviceName ?? tracer.serviceName,
    traceId: upstreamTraceId ?? TraceId.generate(),
    parentId: parentId,
  );

  final method = request.method;
  final urlPath = request.uri.path.isEmpty ? '/' : request.uri.path;

  return tracer.run(
    segment,
    () async {
      try {
        return await handler();
      } finally {
        final response = request.response;
        // Record the request and response on the segment so this node appears
        // in the X-Ray service map with method/url/status. `traced: true`
        // marks that the trace header was forwarded downstream. Recorded in
        // the finally so a thrown handler still captures the response status.
        // Reading status/contentLength is safe even if the body is closed.
        tracer.recordSegmentHttp(HttpData(
          request: HttpRequestData(
            method: method,
            url: request.uri.toString(),
            traced: true,
          ),
          response: HttpResponseData(
            status: response.statusCode,
            contentLength:
                response.contentLength >= 0 ? response.contentLength : null,
          ),
        ));
        // Read tracer.isSampled inside the zone so it reflects the real
        // decision (outside a zone the getter would fail open to `true`,
        // mislabelling the header as Sampled=1 for unsampled traces).
        // The response may already have been closed — headers are immutable
        // and the set throws; we swallow the error.
        try {
          response.headers.set(
            'x-amzn-trace-id',
            buildTraceHeader(
              traceId: segment.traceId.toString(),
              segmentId: segment.id,
              sampled: tracer.isSampled,
            ),
          );
        } catch (_) {}
      }
    },
    httpMethod: method,
    urlPath: urlPath,
  );
}
