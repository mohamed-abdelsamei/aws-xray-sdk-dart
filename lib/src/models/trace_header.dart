/// Builds the `X-Amzn-Trace-Id` header value.
///
/// [traceId] is the string form of the root trace ID (`1-{8 hex}-{24 hex}`) and
/// [segmentId] is the parent segment/subsegment id (16 hex chars). In normal SDK
/// flow these come from a real [TraceId] and a generated id, so they are always
/// valid.
///
/// Validation is symmetric with the parser ([TraceId.tryParse]) but enforced via
/// an [assert]: in debug/tests malformed input fails loudly (catching a caller
/// bug), while in production the header is built best-effort and never throws —
/// header injection runs on the request hot path and tracing must never break
/// the application. A malformed header is no worse than the daemon dropping it.
String buildTraceHeader({
  required String traceId,
  required String segmentId,
  required bool sampled,
}) {
  assert(
    _isValidTraceId(traceId),
    'buildTraceHeader: "$traceId" is not a valid X-Ray trace id '
    '(1-{8 hex}-{24 hex})',
  );
  assert(
    _isHexId(segmentId, 16),
    'buildTraceHeader: "$segmentId" is not a valid 16-hex segment id',
  );
  return 'Root=$traceId;Parent=$segmentId;Sampled=${sampled ? 1 : 0}';
}

bool _isValidTraceId(String value) {
  final parts = value.split('-');
  if (parts.length != 3 || parts[0] != '1') return false;
  return _isHexId(parts[1], 8) && _isHexId(parts[2], 24);
}

bool _isHexId(String value, int length) {
  if (value.length != length) return false;
  for (var i = 0; i < value.length; i++) {
    final c = value.codeUnitAt(i);
    final isDigit = c >= 0x30 && c <= 0x39; // 0-9
    final isLower = c >= 0x61 && c <= 0x66; // a-f
    final isUpper = c >= 0x41 && c <= 0x46; // A-F
    if (!isDigit && !isLower && !isUpper) return false;
  }
  return true;
}
