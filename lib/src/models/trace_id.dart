import '../utils.dart' show randomHex;

/// X-Ray trace ID in the format `1-{8-hex-epoch-s}-{24-hex-random}`.
final class TraceId {
  TraceId._(this._value);

  final String _value;

  /// Generates a new trace ID with the current timestamp.
  factory TraceId.generate() {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final ts = now.toRadixString(16).padLeft(8, '0');
    return TraceId._('1-$ts-${randomHex(24)}');
  }

  /// Parses a trace ID from the `X-Amzn-Trace-Id` header value.
  ///
  /// Returns `null` if [value] is not a valid X-Ray trace ID.
  static TraceId? tryParse(String value) {
    final root = _extractField(value, 'Root');
    if (root == null) return null;
    final parts = root.split('-');
    if (parts.length != 3 || parts[0] != '1') return null;
    if (parts[1].length != 8 || parts[2].length != 24) return null;
    return TraceId._(root);
  }

  /// The validated `Root` trace ID from an `X-Amzn-Trace-Id` header, as a
  /// plain string, or `null` if the header carries no valid trace ID.
  ///
  /// The common case for log enrichment: callers want the root id as a string
  /// without constructing a [TraceId]. Equivalent to `tryParse(header)?.toString()`,
  /// so the same validation rules apply.
  ///
  /// ```dart
  /// loggingContext['xrayTraceId'] = TraceId.parseRootString(header);
  /// ```
  static String? parseRootString(String headerValue) =>
      tryParse(headerValue)?.toString();

  /// The parent segment ID embedded in an `X-Amzn-Trace-Id` header, if any.
  static String? parseParentId(String headerValue) =>
      _extractField(headerValue, 'Parent');

  /// Whether the sampling decision in [headerValue] is sampled (`Sampled=1`).
  static bool? parseSampled(String headerValue) {
    final s = _extractField(headerValue, 'Sampled');
    if (s == '1') return true;
    if (s == '0') return false;
    return null;
  }

  @override
  String toString() => _value;

  static String? _extractField(String header, String key) {
    for (final part in header.split(';')) {
      final trimmed = part.trim();
      final eq = trimmed.indexOf('=');
      if (eq == -1) continue;
      final k = trimmed.substring(0, eq).trim();
      if (k == key) return trimmed.substring(eq + 1).trim();
    }
    return null;
  }
}
