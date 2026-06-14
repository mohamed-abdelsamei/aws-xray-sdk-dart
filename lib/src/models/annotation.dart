/// Annotation validation helpers shared by every annotation entry point
/// (`XRayTracer.annotate`, the `TraceContext` handle, and `Segment` /
/// `Subsegment.annotate`).
///
/// AWS X-Ray imposes two hard constraints on **annotations** (the indexed,
/// filter-expression-searchable key/value pairs):
///
/// - keys may contain only the characters `A-Z`, `a-z`, `0-9`, and `_`;
/// - values must be one of the scalar types `String`, `bool`, `int`, or
///   `double`.
///
/// The SDK enforces these by **sanitizing**, never by throwing: a malformed
/// annotation must not lose the whole trace or fault the traced operation
/// (consistent with the package's "tracing must never break the application"
/// principle). An invalid key has each disallowed character replaced with `_`;
/// a non-scalar value is coerced to a `String` via `toString()`.
///
/// Metadata (the non-indexed block) is *not* validated here — X-Ray accepts
/// arbitrary JSON-serializable metadata; see `Subsegment.addMetadata` /
/// `XRayTracer.addMetadata` for the documented metadata constraints.
library;

/// Characters X-Ray permits in an annotation key.
final RegExp _invalidKeyChar = RegExp(r'[^A-Za-z0-9_]');

/// Returns [key] with every character X-Ray disallows in an annotation key
/// (anything outside `[A-Za-z0-9_]`) replaced by `_`.
///
/// An empty key — or one made entirely of disallowed characters, which would
/// sanitize to an empty string — becomes the single placeholder `_` so the
/// annotation still has a usable, X-Ray-valid key.
String sanitizeAnnotationKey(String key) {
  final sanitized = key.replaceAll(_invalidKeyChar, '_');
  return sanitized.isEmpty ? '_' : sanitized;
}

/// Returns [value] unchanged when it is a valid scalar X-Ray annotation value
/// (`String`, `bool`, `int`, or `double`); otherwise coerces it to its
/// `toString()` representation so the annotation remains X-Ray-valid.
Object coerceAnnotationValue(Object value) {
  if (value is String || value is bool || value is int || value is double) {
    return value;
  }
  return value.toString();
}
