import 'dart:io';

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

  return tracer.run(segment, () async {
    try {
      return await handler();
    } finally {
      // Read tracer.isSampled inside the zone so it reflects the real
      // decision (outside a zone the getter would fail open to `true`,
      // mislabelling the header as Sampled=1 for unsampled traces).
      // The response may already have been closed — headers are immutable
      // and the set throws; we swallow the error.
      try {
        request.response.headers.set(
          'x-amzn-trace-id',
          buildTraceHeader(
            traceId: segment.traceId.toString(),
            segmentId: segment.id,
            sampled: tracer.isSampled,
          ),
        );
      } catch (_) {}
    }
  });
}
