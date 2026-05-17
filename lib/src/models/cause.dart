import '../utils.dart';

/// Represents the error cause recorded in a segment or subsegment.
final class Cause {
  const Cause({
    this.workingDirectory,
    this.exceptions = const [],
  });

  final String? workingDirectory;
  final List<XRayException> exceptions;

  Map<String, Object?> toJson() => {
        if (workingDirectory != null) 'working_directory': workingDirectory,
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
        id: _generateId(),
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

  static String _generateId() => randomHex(16);
}
