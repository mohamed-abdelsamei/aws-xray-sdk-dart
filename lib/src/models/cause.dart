import '../utils.dart';
import 'http_data.dart';

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
  /// URLs in the message are redacted to `scheme://host[:port]/path`
  /// first, then messages longer than 1024 UTF-16 code units are
  /// truncated and end with `…[truncated]`.
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

  /// The single place an error becomes a recorded message: guard, then
  /// redact URLs, then truncate. Redacting first means a URL straddling the
  /// cap cannot leave a partial password behind.
  static String _safeMessage(Object error, String fallback) {
    String raw;
    try {
      raw = error.toString();
    } catch (_) {
      raw = fallback;
    }
    return truncateMessage(redactUrlsInText(raw));
  }

  final String id;
  final String type;

  /// The message as given. For an entry built by [XRayException.from] it is
  /// already redacted and truncated; for a user-built entry it stays raw, and
  /// only [toJson] emits it with URLs redacted (not truncated).
  final String message;
  final bool remote;

  Map<String, Object?> toJson() => {
        'id': id,
        'type': type,
        'message': redactUrlsInText(message),
        if (remote) 'remote': true,
      };
}
