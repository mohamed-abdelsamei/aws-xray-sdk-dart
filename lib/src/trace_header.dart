/// Builds the `X-Amzn-Trace-Id` header value.
///
/// [traceId] is the string form of the root trace ID (`1-xxxx-xxxx`).
String buildTraceHeader({
  required String traceId,
  required String segmentId,
  required bool sampled,
}) =>
    'Root=$traceId;Parent=$segmentId;Sampled=${sampled ? 1 : 0}';
