import 'aws_data.dart';
import 'cause.dart';
import 'http_data.dart';
import 'subsegment.dart';
import 'trace_id.dart';
import '../utils.dart';

/// Top-level X-Ray trace unit.
///
/// Segments are immutable value objects; every mutation returns a new copy.
final class Segment {
  Segment._({
    required this.id,
    required this.traceId,
    required this.name,
    required this.startTime,
    required this.inProgress,
    this.endTime,
    this.parentId,
    this.namespace,
    this.fault = false,
    this.error = false,
    this.throttle = false,
    this.cause,
    this.http,
    this.aws,
    this.annotations,
    this.metadata, // Map<String, Map<String, Object>>
    this.subsegments = const [],
    this.service,
    this.user,
    this.origin,
  });

  final String id;
  final TraceId traceId;
  final String name;
  final double startTime;
  final double? endTime;
  final bool inProgress;
  final String? parentId;
  final String? namespace;
  final bool fault;
  final bool error;
  final bool throttle;
  final Cause? cause;
  final HttpData? http;
  final AwsData? aws;
  final Map<String, Object>? annotations;
  // X-Ray schema: {"namespace": {"key": value}}
  final Map<String, Map<String, Object>>? metadata;
  final List<Subsegment> subsegments;
  final Map<String, Object>? service;
  final String? user;
  final String? origin;

  factory Segment.begin({
    required String name,
    required TraceId traceId,
    String? parentId,
    String? namespace,
    String? user,
    String? origin,
  }) =>
      Segment._(
        id: _generateId(),
        traceId: traceId,
        name: name,
        startTime: _nowSeconds(),
        inProgress: true,
        parentId: parentId,
        namespace: namespace,
        user: user,
        origin: origin,
      );

  /// Returns a closed copy with [endTime] set.
  ///
  /// Calling this on an already-closed segment (i.e. [endTime] is non-null)
  /// is a no-op — the original timing is preserved.
  Segment close() {
    if (endTime != null) return this;
    return _copyWith(endTime: _nowSeconds(), inProgress: false);
  }

  Segment withFault([Object? err]) => _copyWith(
        fault: true,
        cause: err != null ? Cause(exceptions: [XRayException.from(err)]) : cause,
      );

  Segment withError([Object? err]) => _copyWith(
        error: true,
        cause: err != null ? Cause(exceptions: [XRayException.from(err)]) : cause,
      );

  Segment withThrottle() => _copyWith(throttle: true, error: true);

  Segment addSubsegment(Subsegment sub) =>
      _copyWith(subsegments: [...subsegments, sub]);

  Segment annotate(String key, Object value) =>
      _copyWith(annotations: {...?annotations, key: value});

  Segment addMetadata(
    String key,
    Object value, {
    String namespace = 'default',
  }) {
    final updated = <String, Map<String, Object>>{...?metadata};
    updated[namespace] = {...?updated[namespace], key: value};
    return _copyWith(metadata: updated);
  }

  Map<String, Object?> toJson() => {
        'trace_id': traceId.toString(),
        'id': id,
        'name': name,
        'start_time': startTime,
        if (endTime != null) 'end_time': endTime,
        if (inProgress) 'in_progress': true,
        if (parentId != null) 'parent_id': parentId,
        if (namespace != null) 'namespace': namespace,
        if (fault) 'fault': true,
        if (error) 'error': true,
        if (throttle) 'throttle': true,
        if (cause != null) 'cause': cause!.toJson(),
        if (http != null) 'http': http!.toJson(),
        if (aws != null) 'aws': aws!.toJson(),
        if (annotations != null) 'annotations': annotations,
        if (metadata != null) 'metadata': metadata,
        if (service != null) 'service': service,
        if (user != null) 'user': user,
        if (origin != null) 'origin': origin,
        if (subsegments.isNotEmpty)
          'subsegments': [for (final s in subsegments) s.toJson()],
      };

  Segment _copyWith({
    double? endTime,
    bool? inProgress,
    bool? fault,
    bool? error,
    bool? throttle,
    Cause? cause,
    HttpData? http,
    AwsData? aws,
    Map<String, Object>? annotations,
    Map<String, Map<String, Object>>? metadata,
    List<Subsegment>? subsegments,
  }) =>
      Segment._(
        id: id,
        traceId: traceId,
        name: name,
        startTime: startTime,
        endTime: endTime ?? this.endTime,
        inProgress: inProgress ?? this.inProgress,
        parentId: parentId,
        namespace: namespace,
        fault: fault ?? this.fault,
        error: error ?? this.error,
        throttle: throttle ?? this.throttle,
        cause: cause ?? this.cause,
        http: http ?? this.http,
        aws: aws ?? this.aws,
        annotations: annotations ?? this.annotations,
        metadata: metadata ?? this.metadata,
        subsegments: subsegments ?? this.subsegments,
        service: service,
        user: user,
        origin: origin,
      );

  static String _generateId() => randomHex(16);

  static double _nowSeconds() => nowSeconds();
}
