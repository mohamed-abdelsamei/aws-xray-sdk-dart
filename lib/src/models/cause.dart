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

  factory XRayException.from(Object error) => XRayException(
        id: randomHex(16),
        type: error.runtimeType.toString(),
        message: error.toString(),
      );

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
