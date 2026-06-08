import 'dart:io';

import '../models/segment.dart';
import '../models/trace_id.dart';
import '../tracer.dart';
import '../wrappers/xray_interceptor.dart' show buildTraceHeader;

/// Extracts X-Ray trace context from an incoming HTTP request's
/// `X-Amzn-Trace-Id` header and runs [handler] inside [tracer.run].
///
/// If the header carries a `Parent=` (segment ID from the upstream service),
/// it is set on the segment so the X-Ray service map correctly links this
/// service as a downstream node.
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

  // Captured inside the run zone where tracer.isSampled reflects the real
  // decision. Read in the finally block — after run() returns — the getter
  // would be outside the zone and fail open to `true`, mislabelling the
  // outgoing header as Sampled=1 for unsampled traces.
  var sampled = true;
  try {
    return await tracer.run(segment, () async {
      sampled = tracer.isSampled;
      return await handler();
    });
  } finally {
    // Attempt to set the trace-id header on the response so downstream
    // services can continue the trace. The response may already have been
    // closed by the handler — in that case headers are immutable and the
    // set throws; we swallow the error.
    try {
      request.response.headers.set(
        'x-amzn-trace-id',
        buildTraceHeader(
          traceId: segment.traceId.toString(),
          segmentId: segment.id,
          sampled: sampled,
        ),
      );
    } catch (_) {}
  }
}
