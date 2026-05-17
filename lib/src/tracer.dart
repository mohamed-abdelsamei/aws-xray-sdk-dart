import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'models/segment.dart';
import 'models/subsegment.dart';
import 'models/trace_id.dart';
import 'sampling/fixed_rate_sampler.dart';
import 'sampling/sampling_strategy.dart';
import 'sender/segment_encoder.dart';
import 'sender/sender.dart';
import 'sender/udp_sender.dart';

// Zone key for the active segment.
final _zoneKey = #_xraySegment;

// Zone key for the mutable subsegment list being built in this zone.
final _subsegmentsKey = #_xraySubsegments;

// Zone key for the sampling decision made at run() entry.
final _sampledKey = #_xraySampled;

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
    String daemonHost = '127.0.0.1',
    int daemonPort = 2000,
  })  : _sender = sender ?? UdpSender(host: daemonHost, port: daemonPort),
        _sampling = sampling ?? FixedRateSampler(0.05);

  final String serviceName;
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
    // Make the sampling decision once, before any work begins.
    final sampled = _sampling.shouldSample(SamplingRequest(
      serviceName: serviceName,
      httpMethod: httpMethod,
      urlPath: urlPath,
    ));

    // Mutable list accumulates subsegments added during this zone's lifetime.
    final subs = <Subsegment>[];

    return runZoned(
      () async {
        try {
          return await fn();
        } finally {
          final closed = segment.close();
          final withSubs = subs.fold(closed, (s, sub) => s.addSubsegment(sub));
          await closeSegment(withSubs);
        }
      },
      zoneValues: {
        _zoneKey: segment,
        _subsegmentsKey: subs,
        _sampledKey: sampled,
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
    final subs = <Subsegment>[];
    final startMs = DateTime.now().millisecondsSinceEpoch;

    // A virtual segment is stored in the zone so that [currentSegment] is
    // non-null and [XRayHttpClient] can read the correct traceId for outbound
    // `X-Amzn-Trace-Id` header injection.  Its auto-generated id becomes the
    // handler subsegment's id.
    final virtualSegment = Segment.begin(
      name: name,
      traceId: traceId,
      parentId: lambdaParentId,
    );

    return runZoned(
      () async {
        try {
          return await fn();
        } finally {
          final endMs = DateTime.now().millisecondsSinceEpoch;

          // Build the handler subsegment JSON.
          final handlerDoc = <String, Object?>{
            'name': name,
            'id': virtualSegment.id,
            'start_time': startMs / 1000.0,
            'end_time': endMs / 1000.0,
            if (subs.isNotEmpty)
              'subsegments': subs.map((s) => s.toJson()).toList(),
          };

          final packet = encodeSubsegmentDoc(
            handlerDoc,
            lambdaParentId,
            traceId.toString(),
          );
          // Debug: log exactly what we're about to send to the daemon.
          stderr.writeln(
              '[XRay runLambda] sampled=$sampled packet=${packet.length}B '
              'content=${utf8.decode(packet)}');
          if (sampled) {
            try {
              await _sender.sendPackets([packet]);
              stderr.writeln('[XRay runLambda] sendPackets completed OK');
            } catch (e, st) {
              stderr.writeln('[XRay runLambda] sendPackets ERROR: $e\n$st');
            }
          } else {
            stderr.writeln('[XRay runLambda] not sampled — skipped');
          }
        }
      },
      zoneValues: {
        _zoneKey: virtualSegment,
        _subsegmentsKey: subs,
        _sampledKey: sampled,
      },
    );
  }

  /// The segment active in the current [Zone], or `null` if none.
  Segment? get currentSegment => Zone.current[_zoneKey] as Segment?;

  /// Opens a subsegment and registers it in the current zone's list.
  ///
  /// Call [endSubsegment] or [failSubsegment] to close it.
  Subsegment beginSubsegment(String name, {String namespace = 'local'}) =>
      Subsegment.begin(name: name, namespace: namespace);

  /// Closes [sub] and attaches it to the active segment.
  void endSubsegment(Subsegment sub) {
    final closed = sub.close();
    _attachSubsegment(closed);
  }

  /// Closes [sub] as faulted and attaches it to the active segment.
  void failSubsegment(Subsegment sub, Object error) {
    final closed = sub.withFault(error).close();
    _attachSubsegment(closed);
  }

  void _attachSubsegment(Subsegment sub) {
    final subs = Zone.current[_subsegmentsKey] as List<Subsegment>?;
    subs?.add(sub);
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
  Future<void> closeSegment(Segment segment) async {
    if (!isSampled) return;
    await _sender.send(segment);
  }

  /// Creates a new segment with a fresh trace ID.
  Segment beginSegment({String? parentId, String? user}) => Segment.begin(
        name: serviceName,
        traceId: TraceId.generate(),
        parentId: parentId,
        user: user,
      );

  Future<void> close() => _sender.close();
}
