import 'dart:async';
import 'dart:io';
import 'models/http_data.dart';
import 'models/segment.dart';
import 'models/subsegment.dart';
import 'models/trace_id.dart';
import 'sampling/fixed_rate_sampler.dart';
import 'sampling/sampling_strategy.dart';
import 'sender/noop_sender.dart';
import 'sender/segment_encoder.dart';
import 'sender/sender.dart';
import 'sender/udp_sender.dart';
import 'trace_scope.dart';

export 'trace_scope.dart' show TraceContext;

// Zone key for the active segment.
final _zoneKey = #_xraySegment;

// Zone key for the per-trace mutable state (root scope + pending subsegments).
final _stateKey = #_xrayState;

// Zone key for the current open scope (the root, or a captureAsync child).
final _currentScopeKey = #_xrayCurrentScope;

// Zone key for the sampling decision made at run() entry.
final _sampledKey = #_xraySampled;

/// What to do when a subsegment is recorded but there is no active trace in
/// the current zone to attach it to (the data would otherwise be dropped).
///
/// `ignore` keeps the default fire-and-forget behavior (the data is dropped
/// silently). `logError` writes a diagnostic to `stderr`. `runtimeError`
/// throws a `StateError`, surfacing missing instrumentation early in tests.
///
/// Note: this does **not** affect the traced HTTP clients, which intentionally
/// pass requests through untraced when used outside a [XRayTracer.run] zone.
enum ContextMissingPolicy {
  ignore,
  logError,
  runtimeError,
}

// The process-wide default tracer, or null until one is installed (see
// [defaultTracer] / [XRay.configure]). Lives here, not on the XRay facade, so
// XRayBaseClient can resolve it without importing the facade (avoiding an
// import cycle).
XRayTracer? _defaultTracer;
XRayTracer? _noopTracer;

/// The process-wide default [XRayTracer]: the installed tracer, or a shared
/// no-op (discards everything) when none has been installed. Instrumentation
/// resolves this so it can run unconditionally and simply do nothing when
/// tracing is unconfigured.
///
/// Prefer the `XRay.tracer` / `XRay.configure` API over using this directly.
XRayTracer get defaultTracer =>
    _defaultTracer ??
    (_noopTracer ??= XRayTracer(
      serviceName: 'unconfigured',
      sender: NoopSender(),
      sampling: FixedRateSampler(0.0),
    ));

/// Installs (or clears, with null) the process-wide default tracer.
set defaultTracer(XRayTracer? value) => _defaultTracer = value;

/// Whether a real (non-no-op) default tracer has been installed.
bool get isDefaultTracerConfigured => _defaultTracer != null;

/// Central X-Ray tracing context.
///
/// Create one instance per service and share it across your application:
/// ```dart
/// final tracer = XRayTracer(serviceName: 'order-service');
/// ```
final class XRayTracer {
  XRayTracer({
    required this.serviceName,
    Sender? sender,
    SamplingStrategy? sampling,
    this.contextMissingPolicy = ContextMissingPolicy.ignore,
    String daemonHost = '127.0.0.1',
    int daemonPort = 2000,
  })  : _sender = sender ?? UdpSender(host: daemonHost, port: daemonPort),
        _sampling = sampling ?? FixedRateSampler(0.05);

  final String serviceName;
  final ContextMissingPolicy contextMissingPolicy;
  final Sender _sender;
  final SamplingStrategy _sampling;

  /// Runs [fn] with [segment] as the active trace context.
  ///
  /// All `await`-ed calls inside [fn] inherit the zone and can call
  /// [currentSegment] to access the active segment.
  ///
  /// The sampling decision is made **once** at entry using [httpMethod] and
  /// [urlPath] (both optional, defaulting to `'UNKNOWN'`/`'/'`). It is stored
  /// in the zone so that every downstream subsegment header injection uses the
  /// same decision, and `closeSegment` consults it rather than re-evaluating.
  ///
  /// On completion (success or error) the segment is closed and sent if sampled.
  Future<T> run<T>(
    Segment segment,
    Future<T> Function() fn, {
    String httpMethod = 'UNKNOWN',
    String urlPath = '/',
  }) {
    final sampled = _sampling.shouldSample(SamplingRequest(
      serviceName: serviceName,
      httpMethod: httpMethod,
      urlPath: urlPath,
    ));

    return _runZoned(
      segment,
      fn,
      sampled: sampled,
      onComplete: (root) async {
        await closeSegment(root.applyToSegment(segment));
      },
    );
  }

  /// Runs [fn] in a Lambda environment where `provided:al2023` has already
  /// created the root `AWS::Lambda::Function` segment.
  ///
  /// Instead of emitting a competing top-level segment (which the X-Ray daemon
  /// silently drops), this method emits a single **independent subsegment
  /// document** whose `parent_id` is [lambdaParentId] — the ID of the
  /// auto-created function segment taken from the `Parent=` field of the
  /// `Lambda-Runtime-Trace-Id` header.
  ///
  /// All subsegments opened during [fn] (via [beginSubsegment] /
  /// [endSubsegment] / [failSubsegment]) are embedded inside the handler
  /// subsegment before it is sent, producing a trace like:
  ///
  /// ```
  /// AWS::Lambda (facade)  [auto]
  ///   AWS::Lambda::Function  [auto, id = lambdaParentId]
  ///     <name>  [our handler subsegment]
  ///       validation
  ///       some-downstream-host
  /// ```
  ///
  /// [traceId]        — parsed from `Root=` in the Lambda trace header.
  /// [lambdaParentId] — parsed from `Parent=` in the Lambda trace header.
  /// [name]           — label for the handler subsegment in the service map.
  /// [sampled]        — parsed from `Sampled=` in the Lambda trace header.
  Future<T> runLambda<T>(
    TraceId traceId,
    String lambdaParentId,
    String name,
    Future<T> Function() fn, {
    bool sampled = true,
  }) {
    // A virtual segment is stored in the zone so that [currentSegment] is
    // non-null and [XRayHttpClient] can read the correct traceId for outbound
    // `X-Amzn-Trace-Id` header injection.  Its auto-generated id becomes the
    // handler subsegment's id.
    final virtualSegment = Segment.begin(
      name: name,
      traceId: traceId,
      parentId: lambdaParentId,
    );

    return _runZoned(
      virtualSegment,
      fn,
      sampled: sampled,
      onComplete: (root) async {
        // The handler span is a real subsegment: it carries nested children,
        // any annotations/metadata set during the invocation, and a fault when
        // the handler throws. `namespace` is dropped — a Lambda handler span is
        // not an `aws`/`remote` downstream call.
        final doc = root.toSubsegment().toJson()..remove('namespace');
        final packet = encodeSubsegmentDoc(
          doc,
          lambdaParentId,
          traceId.toString(),
        );
        if (sampled) await _sender.sendPackets([packet]);
      },
    );
  }

  /// Shared zone scaffolding for [run] and [runLambda].
  ///
  /// Stores [segment], a fresh root [TraceScope] (the accumulator for nested
  /// subsegments, annotations, and metadata), and [sampled] in a new zone, runs
  /// [fn], then calls [onComplete] with the root scope in a `finally` block so
  /// the span is always closed and delivered. An uncaught error from [fn] is
  /// recorded as a fault on the root before it propagates.
  Future<T> _runZoned<T>(
    Segment segment,
    Future<T> Function() fn, {
    required bool sampled,
    required Future<void> Function(TraceScope root) onComplete,
  }) {
    final root = TraceScope.root(
      id: segment.id,
      name: segment.name,
      namespace: segment.namespace ?? 'local',
      startTime: segment.startTime,
    );
    final state = TraceState(root);
    return runZoned(
      () async {
        try {
          return await fn();
        } catch (e) {
          root.recordUncaught(e);
          rethrow;
        } finally {
          // Transport containment: a Sender (or scope-serialization) failure
          // during finalization must never fault or mask the traced operation.
          // A throw from this `finally` would supersede fn's return value or its
          // original exception, so it is swallowed here. The tracer contains
          // silently; per-Sender observability (e.g. UdpSender.onError) is each
          // sender's concern.
          try {
            // Close any span whose body stream was never drained (so its
            // close never fired) and attach it to its parent before
            // serialization — otherwise it would be silently dropped. Runs
            // inside this containment so a sweep throw can never escape.
            state.sweep();
            await onComplete(root);
          } catch (_) {
            // Intentionally ignored — tracing must never break the application.
          }
        }
      },
      zoneValues: {
        _zoneKey: segment,
        _stateKey: state,
        _currentScopeKey: root,
        _sampledKey: sampled,
      },
    );
  }

  /// The segment active in the current [Zone], or `null` if none.
  ///
  /// This getter is side-effect free. A `null` result is the normal
  /// "no active trace" signal — the traced HTTP clients use it to pass a
  /// request through untraced when called outside a [run] zone — so it never
  /// logs or throws. The [contextMissingPolicy] is applied where trace data
  /// would actually be lost; see [endSubsegment] / [failSubsegment].
  Segment? get currentSegment => Zone.current[_zoneKey] as Segment?;

  /// The [TraceId] of the active segment, or `null` if no trace is active.
  ///
  /// Convenience inside a [run] or [runLambda] callback so callers can write
  /// `tracer.currentTraceId` instead of `tracer.currentSegment?.traceId`.
  TraceId? get currentTraceId => currentSegment?.traceId;

  /// Applies [contextMissingPolicy] when a subsegment is recorded but there is
  /// no active trace in the current zone to attach it to (so the data would be
  /// silently dropped).
  void _handleContextMissing() {
    const message = 'AWS X-Ray context is missing in the current zone; '
        'subsegment data was dropped. Wrap the work in XRayTracer.run().';
    switch (contextMissingPolicy) {
      case ContextMissingPolicy.ignore:
        return;
      case ContextMissingPolicy.logError:
        stderr.writeln('X-Ray context missing: $message');
        return;
      case ContextMissingPolicy.runtimeError:
        throw StateError(message);
    }
  }

  /// The scope currently being traced — the root (segment) or the innermost
  /// open [captureAsync] scope. `null` outside any [run] zone.
  TraceScope? get _currentScope =>
      Zone.current[_currentScopeKey] as TraceScope?;

  /// Runs [body] as a nested subsegment named [name], correctly parented under
  /// whatever scope is active, and closes it when [body] completes.
  ///
  /// Unlike [beginSubsegment]/[endSubsegment] (which produce flat, sibling
  /// subsegments), this nests: any subsegment opened inside [body] — manually
  /// or by an auto-instrumented HTTP/AWS client — becomes a *child* of this
  /// one. The scope is bound to a forked [Zone], so concurrent `captureAsync`
  /// calls stay independent (no cross-talk between parallel branches).
  ///
  /// The [TraceContext] passed to [body] lets you [TraceContext.annotate],
  /// [TraceContext.addMetadata], or mark [TraceContext.setError] /
  /// [TraceContext.setFault] on this subsegment. An uncaught error from [body]
  /// is recorded as a fault and rethrown.
  ///
  /// ```dart
  /// await tracer.captureAsync('process-order', (span) async {
  ///   span.annotate('orderId', id);
  ///   await ddb.putItem(...);   // nested under 'process-order'
  /// });
  /// ```
  ///
  /// Called outside a [run] zone, [body] runs untraced (fail-open) with a
  /// no-op context.
  Future<T> captureAsync<T>(
    String name,
    Future<T> Function(TraceContext span) body, {
    String namespace = 'local',
  }) {
    final parent = _currentScope;
    if (parent == null) {
      _handleContextMissing();
      return body(const NoopTraceContext());
    }
    final state = Zone.current[_stateKey] as TraceState?;
    final scope = TraceScope.child(
      name: name,
      namespace: namespace,
      parent: parent,
    );
    return runZoned(
      () async {
        try {
          return await body(scope);
        } catch (e) {
          scope.recordUncaught(e);
          rethrow;
        } finally {
          state?.sweep(parent: scope);
          parent.addChild(scope.toSubsegment());
        }
      },
      zoneValues: {_currentScopeKey: scope},
    );
  }

  /// Adds an indexed annotation to the entity currently being traced (the
  /// active [captureAsync] subsegment, or the segment itself).
  ///
  /// X-Ray restricts annotation **keys** to `[A-Za-z0-9_]` and **values** to
  /// the scalars `String` / `bool` / `int` / `double`. Invalid input is
  /// sanitized, not rejected: bad key characters become `_` and a non-scalar
  /// value is coerced to its `toString()`. Use [addMetadata] for structured or
  /// non-scalar data.
  void annotate(String key, Object value) {
    final scope = _currentScope;
    if (scope == null) {
      _handleContextMissing();
      return;
    }
    scope.annotate(key, value);
  }

  /// Adds every entry of [annotations] to the entity currently being traced.
  ///
  /// A bulk form of [annotate] (same key/value sanitization rules). The context
  /// is resolved once: if there is no active trace, the whole batch is dropped
  /// and [contextMissingPolicy] is applied a single time.
  void annotateAll(Map<String, Object> annotations) {
    final scope = _currentScope;
    if (scope == null) {
      _handleContextMissing();
      return;
    }
    annotations.forEach(scope.annotate);
  }

  /// Adds non-indexed metadata to the entity currently being traced.
  ///
  /// Metadata is not indexed (not searchable via filter expressions) and is not
  /// validated: [value] may be any JSON-serializable object. Avoid the `AWS.`
  /// namespace prefix, which X-Ray reserves for its own use.
  void addMetadata(String key, Object value, {String namespace = 'default'}) {
    final scope = _currentScope;
    if (scope == null) {
      _handleContextMissing();
      return;
    }
    scope.addMetadata(key, value, namespace: namespace);
  }

  /// Opens a subsegment to be closed with [endSubsegment] or [failSubsegment].
  ///
  /// The subsegment is parented under whatever scope is active when this is
  /// called (the segment root, or an enclosing [captureAsync]); the link is
  /// captured now so close can happen later, in a different zone (e.g. after an
  /// HTTP response body is consumed). For nesting work *inside* a subsegment,
  /// prefer [captureAsync].
  Subsegment beginSubsegment(String name, {String namespace = 'local'}) {
    final sub = Subsegment.begin(name: name, namespace: namespace);
    final state = Zone.current[_stateKey] as TraceState?;
    final parent = _currentScope;
    if (state != null && parent != null) {
      state.closedIds.remove(sub.id);
      state.pending[sub.id] = (parent: parent, sub: sub);
    }
    return sub;
  }

  /// Refreshes the pending document for an already-begun subsegment.
  ///
  /// **Internal — called by the SDK's own traced HTTP clients.** Because a
  /// subsegment is immutable, the clients build an enriched copy (status, aws
  /// data, cause) *after* [beginSubsegment]. They register that copy here so a
  /// span swept at finalization (its body never drained) carries the data the
  /// client knew rather than the bare open subsegment. If [sub] is no longer
  /// pending (already attached, or no active trace) this is a no-op.
  void updatePending(Subsegment sub) {
    final state = Zone.current[_stateKey] as TraceState?;
    final entry = state?.pending[sub.id];
    if (state != null && entry != null) {
      state.pending[sub.id] = (parent: entry.parent, sub: sub);
    }
  }

  /// Closes [sub] and attaches it to its parent scope.
  void endSubsegment(Subsegment sub) => _attachSubsegment(sub.close());

  /// Closes [sub] as faulted and attaches it to its parent scope.
  void failSubsegment(Subsegment sub, Object error) =>
      _attachSubsegment(sub.withFault(error).close());

  void _attachSubsegment(Subsegment sub) {
    final state = Zone.current[_stateKey] as TraceState?;
    if (state == null) {
      _handleContextMissing();
      return;
    }
    if (state.closedIds.contains(sub.id)) return;
    final parent =
        state.pending.remove(sub.id)?.parent ?? _currentScope ?? state.root;
    parent.addChild(sub);
    state.closedIds.add(sub.id);
  }

  /// Records HTTP request/response data on the **root segment** of the current
  /// trace (not on any nested [captureAsync] scope).
  ///
  /// Intended for the server middleware, which knows the incoming request and
  /// outgoing response. Folded onto the segment when it is finalized. A no-op
  /// outside a [run] zone.
  void recordSegmentHttp(HttpData http) {
    final state = Zone.current[_stateKey] as TraceState?;
    if (state == null) {
      _handleContextMissing();
      return;
    }
    state.root.setHttp(http);
  }

  /// Whether the current zone's trace is being sampled.
  ///
  /// Returns `true` outside of any [run] zone (fail-open: always sample when
  /// there is no active context, so manually constructed segments are not
  /// silently dropped).
  bool get isSampled => (Zone.current[_sampledKey] as bool?) ?? true;

  /// Serializes and sends [segment] if the current zone's sampling decision
  /// is `true`.
  ///
  /// The decision was made at [run] entry and stored in the zone. Calling this
  /// outside a [run] zone always sends (fail-open).
  ///
  /// A transport or serialization failure is swallowed — finalizing a segment
  /// (whether via [run] or a direct call) must never fault the application.
  Future<void> closeSegment(Segment segment) async {
    if (!isSampled) return;
    try {
      await _sender.send(segment);
    } catch (_) {
      // Intentionally ignored — tracing must never break the application.
    }
  }

  /// Creates a new segment with a fresh trace ID.
  Segment beginSegment({String? parentId, String? user}) => Segment.begin(
        name: serviceName,
        traceId: TraceId.generate(),
        parentId: parentId,
        user: user,
      );

  /// Closes the underlying [Sender]. A transport failure during shutdown is
  /// swallowed — closing the tracer must never throw from the transport.
  Future<void> close() async {
    try {
      await _sender.close();
    } catch (_) {
      // Intentionally ignored — tracing must never break the application.
    }
  }
}
