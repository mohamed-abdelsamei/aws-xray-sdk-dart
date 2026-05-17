import 'aws_data.dart';
import 'cause.dart';
import 'http_data.dart';
import 'sql_data.dart';
import '../utils.dart';

/// A nested span within a [Segment].
///
/// Subsegments are immutable value objects; every mutation returns a new copy.
final class Subsegment {
  Subsegment._({
    required this.id,
    required this.name,
    required this.namespace,
    required this.startTime,
    required this.inProgress,
    this.endTime,
    this.fault = false,
    this.error = false,
    this.throttle = false,
    this.cause,
    this.http,
    this.aws,
    this.sql,
    this.annotations,
    this.metadata,
    this.subsegments = const [],
  });

  final String id;
  final String name;
  final String namespace;
  final double startTime;
  final double? endTime;
  final bool inProgress;
  final bool fault;
  final bool error;
  final bool throttle;
  final Cause? cause;
  final HttpData? http;
  final AwsData? aws;
  final SqlData? sql;
  final Map<String, Object>? annotations;
  // X-Ray schema: {"namespace": {"key": value}}
  final Map<String, Map<String, Object>>? metadata;
  final List<Subsegment> subsegments;

  factory Subsegment.begin({
    required String name,
    String namespace = 'local',
  }) =>
      Subsegment._(
        id: _generateId(),
        name: name,
        namespace: namespace,
        startTime: _nowSeconds(),
        inProgress: true,
      );

  /// Returns a closed copy with [endTime] set.
  Subsegment close() => _copyWith(
        endTime: _nowSeconds(),
        inProgress: false,
      );

  Subsegment withFault([Object? err]) => _copyWith(
        fault: true,
        cause:
            err != null ? Cause(exceptions: [XRayException.from(err)]) : cause,
      );

  Subsegment withError([Object? err]) => _copyWith(
        error: true,
        cause:
            err != null ? Cause(exceptions: [XRayException.from(err)]) : cause,
      );

  Subsegment withThrottle() => _copyWith(throttle: true, error: true);

  Subsegment withHttp(HttpData data) => _copyWith(http: data);

  Subsegment withAws(AwsData data) => _copyWith(aws: data);

  Subsegment withSql(SqlData data) => _copyWith(sql: data);

  Subsegment addChild(Subsegment child) =>
      _copyWith(subsegments: [...subsegments, child]);

  Subsegment annotate(String key, Object value) => _copyWith(
        annotations: {...?annotations, key: value},
      );

  Subsegment addMetadata(
    String key,
    Object value, {
    String namespace = 'default',
  }) {
    final updated = <String, Map<String, Object>>{...?metadata};
    updated[namespace] = {...?updated[namespace], key: value};
    return _copyWith(metadata: updated);
  }

  /// Applies fault/error/throttle flags based on an HTTP status code.
  Subsegment applyStatus(int statusCode) {
    if (statusCode == 429) return withThrottle();
    if (statusCode >= 500) return withFault();
    if (statusCode >= 400) return withError();
    return this;
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'namespace': namespace,
        'start_time': startTime,
        if (endTime != null) 'end_time': endTime,
        if (inProgress) 'in_progress': true,
        if (fault) 'fault': true,
        if (error) 'error': true,
        if (throttle) 'throttle': true,
        if (cause != null) 'cause': cause!.toJson(),
        if (http != null) 'http': http!.toJson(),
        if (aws != null) 'aws': aws!.toJson(),
        if (sql != null) 'sql': sql!.toJson(),
        if (annotations != null) 'annotations': annotations,
        if (metadata != null) 'metadata': metadata,
        if (subsegments.isNotEmpty)
          'subsegments': [for (final s in subsegments) s.toJson()],
      };

  Subsegment _copyWith({
    double? endTime,
    bool? inProgress,
    bool? fault,
    bool? error,
    bool? throttle,
    Cause? cause,
    HttpData? http,
    AwsData? aws,
    SqlData? sql,
    Map<String, Object>? annotations,
    Map<String, Map<String, Object>>? metadata,
    List<Subsegment>? subsegments,
  }) =>
      Subsegment._(
        id: id,
        name: name,
        namespace: namespace,
        startTime: startTime,
        endTime: endTime ?? this.endTime,
        inProgress: inProgress ?? this.inProgress,
        fault: fault ?? this.fault,
        error: error ?? this.error,
        throttle: throttle ?? this.throttle,
        cause: cause ?? this.cause,
        http: http ?? this.http,
        aws: aws ?? this.aws,
        sql: sql ?? this.sql,
        annotations: annotations ?? this.annotations,
        metadata: metadata ?? this.metadata,
        subsegments: subsegments ?? this.subsegments,
      );

  static String _generateId() => randomHex(16);

  static double _nowSeconds() => nowSeconds();
}
