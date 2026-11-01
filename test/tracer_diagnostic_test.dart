import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:aws_xray_sdk/src/sender/segment_encoder.dart' as enc;
import 'package:aws_xray_sdk/src/tracer.dart'
    show newTracerWithUdpSeamsForTesting, reportDiagnostic;
import 'package:test/test.dart';

/// Encodes like UdpSender does (so the encoder can trim) but keeps the
/// packets instead of using a socket.
class _EncodingSender extends Sender {
  final List<List<int>> packets = [];

  @override
  Future<void> send(Segment segment) async =>
      packets.addAll(enc.encode(segment));

  @override
  Future<void> sendPackets(List<List<int>> p) async => packets.addAll(p);

  @override
  Future<void> close() async {}
}

class _ThrowingSender extends Sender {
  @override
  Future<void> send(Segment segment) async => throw StateError('boom');

  @override
  Future<void> sendPackets(List<List<int>> p) async => throw StateError('boom');

  @override
  Future<void> close() async {}
}

final _big = 'x' * 40000;

Future<void> _runBig(XRayTracer t) =>
    t.run(Segment.begin(name: 'svc', traceId: TraceId.generate()), () async {
      // Two 40 KB values: together over the cap, so one gets replaced.
      t.addMetadata('a', _big);
      t.addMetadata('b', _big);
    });

Future<void> _runLambdaBig(XRayTracer t) => t.runLambda(
      TraceId.generate(),
      '53995c3f42cd8ad8',
      'handler-node',
      () async {
        t.addMetadata('a', _big);
        t.addMetadata('b', _big);
      },
    );

void main() {
  group('onDiagnostic: node_trimmed', () {
    test('run() reports a trimmed node with its name and count', () async {
      final got = <XRayDiagnostic>[];
      final t = XRayTracer(
          serviceName: 'svc',
          sampling: FixedRateSampler(1),
          sender: _EncodingSender(),
          onDiagnostic: got.add);
      await _runBig(t);
      expect(got, hasLength(1));
      expect(got.single.code, 'node_trimmed');
      expect(got.single.message, contains('svc'));
      expect(got.single.message, contains('1 metadata value'));
      expect(got.single.error, isNull);
    });

    test('runLambda() reports a trimmed node', () async {
      final got = <XRayDiagnostic>[];
      final t = XRayTracer(
          serviceName: 'svc',
          sampling: FixedRateSampler(1),
          sender: _EncodingSender(),
          onDiagnostic: got.add);
      await _runLambdaBig(t);
      expect(got, hasLength(1));
      expect(got.single.code, 'node_trimmed');
      expect(got.single.message, contains('handler-node'));
    });

    test('a node reduced to a bare node says so', () async {
      final got = <XRayDiagnostic>[];
      final t = XRayTracer(
          serviceName: 'svc',
          sampling: FixedRateSampler(1),
          sender: _EncodingSender(),
          onDiagnostic: got.add);
      await t.run(Segment.begin(name: 'svc', traceId: TraceId.generate()),
          () async {
        // A huge annotation cannot be shortened by replacing metadata.
        t.annotate('k', 'y' * 70000);
      });
      expect(got, hasLength(1));
      expect(got.single.message, contains('bare node'));
    });

    test('nodes that fit produce no diagnostic and unchanged output', () async {
      final got = <XRayDiagnostic>[];
      final withHook = _EncodingSender();
      final without = _EncodingSender();
      final seg = Segment.begin(name: 'svc', traceId: TraceId.generate());
      for (final (s, hook) in [(withHook, got.add), (without, null)]) {
        final t = XRayTracer(
            serviceName: 'svc',
            sampling: FixedRateSampler(1),
            sender: s,
            onDiagnostic: hook);
        await t.closeSegment(seg);
      }
      expect(got, isEmpty);
      expect(withHook.packets, hasLength(1));
      expect(withHook.packets.single, without.packets.single);
    });

    test('many small nodes that each fit: no diagnostic, packets unchanged',
        () async {
      final got = <XRayDiagnostic>[];
      final sender = _EncodingSender();
      final t = XRayTracer(
          serviceName: 'svc',
          sampling: FixedRateSampler(1),
          sender: sender,
          onDiagnostic: got.add);
      var seg = Segment.begin(name: 'svc', traceId: TraceId.generate());
      for (var i = 0; i < 20; i++) {
        seg = seg.addSubsegment(Subsegment.begin(name: 'leaf$i')
            .addMetadata('v', 'z' * 5000)
            .close());
      }
      seg = seg.close();
      await t.closeSegment(seg);
      expect(sender.packets.length, greaterThan(1));
      expect(sender.packets.every((p) => p.length <= 65507), isTrue);
      expect(got, isEmpty);
      expect(sender.packets, enc.encode(seg));
    });

    test('a throwing callback is ignored and the trace is still sent',
        () async {
      final sender = _EncodingSender();
      final t = XRayTracer(
          serviceName: 'svc',
          sampling: FixedRateSampler(1),
          sender: sender,
          onDiagnostic: (_) => throw StateError('hook bug'));
      await _runBig(t);
      expect(sender.packets, hasLength(1));
    });

    test('no callback: same packets as with one', () async {
      final a = _EncodingSender(), b = _EncodingSender();
      await _runBig(XRayTracer(
          serviceName: 'svc', sampling: FixedRateSampler(1), sender: a));
      await _runBig(XRayTracer(
          serviceName: 'svc',
          sampling: FixedRateSampler(1),
          sender: b,
          onDiagnostic: (_) {}));
      expect(a.packets, hasLength(1));
      expect(b.packets, hasLength(1));
    });

    test('the hidden test seam accepts onDiagnostic', () {
      final t = newTracerWithUdpSeamsForTesting(
          serviceName: 'svc', onDiagnostic: (_) {});
      expect(t.onDiagnostic, isNotNull);
    });

    test('the no-op tracer has no hook', () {
      expect(XRay.tracer.onDiagnostic, isNull);
    });
  });

  group('onDiagnostic: dispatcher', () {
    test('a diagnostic raised inside the hook is ignored', () {
      final got = <XRayDiagnostic>[];
      late XRayTracer t;
      t = XRayTracer(
        serviceName: 'svc',
        sampling: FixedRateSampler(1),
        sender: NoopSender(),
        onDiagnostic: (d) {
          got.add(d);
          reportDiagnostic(t, 'adapter_failed', 'nested');
        },
      );
      reportDiagnostic(t, 'adapter_failed', 'first');
      expect(got.map((d) => d.message), ['first']);
      // The guard resets afterwards.
      reportDiagnostic(t, 'adapter_failed', 'second');
      expect(got.map((d) => d.message), [
        'first',
        'second',
      ]);
    });

    test('a throwing hook does not throw out of the dispatcher', () {
      var calls = 0;
      final got = <XRayDiagnostic>[];
      final t = XRayTracer(
        serviceName: 'svc',
        sender: NoopSender(),
        onDiagnostic: (d) {
          calls++;
          if (calls == 1) throw StateError('hook bug');
          got.add(d);
        },
      );
      expect(
          () => reportDiagnostic(t, 'adapter_failed', 'one'), returnsNormally);
      reportDiagnostic(t, 'adapter_failed', 'two');
      expect(got.map((d) => d.message), ['two']);
    });

    test('an async hook that throws after an await does not crash', () async {
      final sender = _EncodingSender();
      final t = XRayTracer(
        serviceName: 'svc',
        sampling: FixedRateSampler(1),
        sender: sender,
        onDiagnostic: (_) async {
          await Future<void>.delayed(Duration.zero);
          throw StateError('late failure');
        },
      );
      await _runBig(t);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(sender.packets, hasLength(1));
    });

    test('carries error and stack trace', () {
      final got = <XRayDiagnostic>[];
      final t = XRayTracer(
          serviceName: 'svc', sender: NoopSender(), onDiagnostic: got.add);
      final st = StackTrace.current;
      reportDiagnostic(t, 'adapter_failed', 'm', error: 'e', stackTrace: st);
      expect(got.single.error, 'e');
      expect(got.single.stackTrace, st);
    });

    test('does not receive send failures; onSendError does', () async {
      final diags = <XRayDiagnostic>[];
      final errors = <Object>[];
      final t = XRayTracer(
        serviceName: 'svc',
        sampling: FixedRateSampler(1),
        sender: _ThrowingSender(),
        onDiagnostic: diags.add,
        onSendError: (_, e) => errors.add(e),
      );
      await t.run(
          Segment.begin(name: 'svc', traceId: TraceId.generate()), () async {});
      await t.runLambda(
          TraceId.generate(), '53995c3f42cd8ad8', 'h', () async {});
      expect(errors, hasLength(2));
      expect(diags, isEmpty);
    });
  });
}
