import 'models/annotation.dart';
import 'models/segment.dart';
import 'models/subsegment.dart';
import 'utils.dart';

/// A live handle to the entity (segment or subsegment) currently being traced.
///
/// Passed to the callback of [XRayTracer.captureAsync] and used by
/// [XRayTracer.annotate] / [XRayTracer.addMetadata] so that mutations apply to
/// the *active* entity. Because the underlying X-Ray models are immutable, you
/// cannot mutate a [Subsegment] in place; this handle records changes that are
/// folded into the immutable document when the scope closes.
abstract interface class TraceContext {
  /// Adds an indexed [annotation](https://docs.aws.amazon.com/xray/latest/devguide/xray-api-segmentdocuments.html#api-segmentdocuments-fields)
  /// — searchable in the X-Ray console via filter expressions.
  ///
  /// X-Ray restricts annotation **keys** to `[A-Za-z0-9_]` and **values** to
  /// the scalar types `String` / `bool` / `int` / `double`. Input that violates
  /// these is sanitized rather than rejected: invalid key characters become
  /// `_`, and a non-scalar value is coerced to its `toString()` — a malformed
  /// annotation never throws or drops the trace.
  void annotate(String key, Object value);

  /// Adds non-indexed [metadata](https://docs.aws.amazon.com/xray/latest/devguide/xray-api-segmentdocuments.html#api-segmentdocuments-fields)
  /// under [namespace] (default `'default'`).
  ///
  /// Unlike [annotate], metadata is not indexed and is **not** validated:
  /// [value] may be any JSON-serializable object (maps, lists, nested values).
  /// Avoid the `AWS.`-prefixed namespace, which X-Ray reserves for its own use.
  void addMetadata(String key, Object value, {String namespace = 'default'});

  /// Marks this entity as an `error` (4xx-class) and records [error] as the cause.
  void setError(Object error);

  /// Marks this entity as a `fault` (5xx-class) and records [error] as the cause.
  void setFault(Object error);
}

/// Mutable runtime accumulator for one open trace entity — the root (segment)
/// or a subsegment opened via [XRayTracer.captureAsync].
///
/// Children, annotations, metadata, and fault state accumulate here while the
/// scope is open, then [toSubsegment] / [applyToSegment] serialize them onto
/// the immutable X-Ray document when the scope closes. Internal — only the
/// tracer constructs these.
final class TraceScope implements TraceContext {
  TraceScope._({
    required this.id,
    required this.name,
    required this.namespace,
    required this.startTime,
    required this.parent,
  });

  /// The root scope mirroring the active [Segment]; uses the segment's id and
  /// start time so header injection and timing stay consistent.
  factory TraceScope.root({
    required String id,
    required String name,
    required String namespace,
    required double startTime,
  }) =>
      TraceScope._(
        id: id,
        name: name,
        namespace: namespace,
        startTime: startTime,
        parent: null,
      );

  /// A nested scope under [parent], with a fresh id and start time.
  factory TraceScope.child({
    required String name,
    required String namespace,
    required TraceScope parent,
  }) =>
      TraceScope._(
        id: randomHex(16),
        name: name,
        namespace: namespace,
        startTime: nowSeconds(),
        parent: parent,
      );

  final String id;
  final String name;
  final String namespace;
  final double startTime;
  final TraceScope? parent;

  final List<Subsegment> _children = [];
  final Map<String, Object> _annotations = {};
  final Map<String, Map<String, Object>> _metadata = {};
  bool _fault = false;
  bool _error = false;
  Object? _errorObject;

  void addChild(Subsegment sub) => _children.add(sub);

  @override
  void annotate(String key, Object value) =>
      _annotations[sanitizeAnnotationKey(key)] = coerceAnnotationValue(value);

  @override
  void addMetadata(String key, Object value, {String namespace = 'default'}) {
    (_metadata[namespace] ??= {})[key] = value;
  }

  @override
  void setError(Object error) {
    _error = true;
    _errorObject = error;
  }

  @override
  void setFault(Object error) {
    _fault = true;
    _errorObject = error;
  }

  /// Records an uncaught error from the captured body as a fault, without
  /// overriding an explicit [setError] / [setFault] already made.
  void recordUncaught(Object error) {
    if (!_fault && !_error) _fault = true;
    _errorObject ??= error;
  }

  /// Materializes this scope as a closed, immutable [Subsegment].
  Subsegment toSubsegment() {
    var sub = Subsegment.open(
      id: id,
      name: name,
      namespace: namespace,
      startTime: startTime,
    );
    for (final child in _children) {
      sub = sub.addChild(child);
    }
    _annotations.forEach((k, v) => sub = sub.annotate(k, v));
    _metadata.forEach((ns, kv) {
      kv.forEach((k, v) => sub = sub.addMetadata(k, v, namespace: ns));
    });
    if (_fault) {
      sub = sub.withFault(_errorObject);
    } else if (_error) {
      sub = sub.withError(_errorObject);
    }
    return sub.close();
  }

  /// Folds this root scope's accumulated state onto [segment] and closes it.
  Segment applyToSegment(Segment segment) {
    var s = segment.close();
    _annotations.forEach((k, v) => s = s.annotate(k, v));
    _metadata.forEach((ns, kv) {
      kv.forEach((k, v) => s = s.addMetadata(k, v, namespace: ns));
    });
    for (final child in _children) {
      s = s.addSubsegment(child);
    }
    if (_fault) {
      s = s.withFault(_errorObject);
    } else if (_error) {
      s = s.withError(_errorObject);
    }
    return s;
  }
}

/// Per-trace mutable state stored once in the run zone and inherited by every
/// nested (captured) zone.
///
/// Holds the [root] scope and a registry mapping an open subsegment's id to the
/// scope that was current when it was begun — so [XRayTracer.endSubsegment] can
/// attach it to the correct parent even when begin and end happen in different
/// zones (e.g. an HTTP response stream consumed after the request returned).
final class TraceState {
  TraceState(this.root);

  final TraceScope root;
  final Map<String, TraceScope> pendingParents = {};
}

/// A no-op [TraceContext] handed to [XRayTracer.captureAsync] when there is no
/// active trace, so the body still runs (fail-open) without recording anything.
final class NoopTraceContext implements TraceContext {
  const NoopTraceContext();

  @override
  void annotate(String key, Object value) {}
  @override
  void addMetadata(String key, Object value, {String namespace = 'default'}) {}
  @override
  void setError(Object error) {}
  @override
  void setFault(Object error) {}
}
