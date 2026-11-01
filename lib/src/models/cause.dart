import '../utils.dart';

/// Represents the error cause recorded in a segment or subsegment.
final class Cause {
  const Cause({
    this.exceptions = const [],
  });

  final List<XRayException> exceptions;

  Map<String, Object?> toJson() => {
        'exceptions': [for (final e in exceptions) e.toJson()],
      };
}

/// One entry in the `exceptions` list of a [Cause].
final class XRayException {
  const XRayException({
    required this.id,
    required this.type,
    required this.message,
    this.remote = false,
  });

  /// Builds an entry from a caught [error]. Never throws: if the error's
  /// `toString()` throws, the message falls back to the runtime type name.
  /// Messages longer than 1024 UTF-16 code units are truncated
  /// and end with `…[truncated]` (ADR 0001).
  factory XRayException.from(Object error) {
    final type = _safeType(error);
    return XRayException(
      id: randomHex(16),
      type: type,
      message: _safeMessage(error, type),
    );
  }

  static String _safeType(Object error) {
    try {
      return error.runtimeType.toString();
    } catch (_) {
      return 'Object';
    }
  }

  /// The single place an error becomes a recorded message: guard, then (a
  /// future redaction step goes here, before truncation) truncate.
  static String _safeMessage(Object error, String fallback) {
    String raw;
    try {
      raw = error.toString();
    } catch (_) {
      raw = fallback;
    }
    return truncateMessage(raw);
  }

  final String id;
  final String type;
  final String message;
  final bool remote;

  Map<String, Object?> toJson() => {
        'id': id,
        'type': type,
        'message': message,
        if (remote) 'remote': true,
      };
}
