// onSendError fires for transport failures of the
// tracer-built UdpSender, at most once per send, and never faults the app.
// Every socket here is an injected fake; no real socket is opened.
import 'dart:io';

import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:aws_xray_sdk/src/tracer.dart'
    show newTracerWithUdpSeamsForTesting;
import 'package:test/test.dart';

// A bound socket whose every datagram send fails locally.
class _FailingSendSocket implements RawDatagramSocket {
  int sends = 0;

  @override
  int send(List<int> buffer, InternetAddress address, int port) {
    sends++;
    throw const SocketException('message too large');
  }

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

typedef _Report = ({Segment segment, Object error});

void main() {
  final traceId = TraceId.generate();
  const parentId = 'abcdef1234567890';

  group('tracer-built UdpSender reports transport failures', () {
    test('bind failure on run: onSendError once, result unchanged', () async {
      final reports = <_Report>[];
      final tracer = newTracerWithUdpSeamsForTesting(
        serviceName: 'svc',
        sampling: FixedRateSampler(1.0),
        socketFactory: (_) async => throw const SocketException('no socket'),
        onSendError: (s, e) => reports.add((segment: s, error: e)),
      );
      final segment = tracer.beginSegment();

      final result = await tracer.run(segment, () async => 42);

      expect(result, 42);
      expect(reports, hasLength(1));
      expect(reports.single.segment.id, segment.id);
      expect(reports.single.error, isA<SocketException>());
    });

    test('resolution failure on run: onSendError once', () async {
      final reports = <_Report>[];
      final tracer = newTracerWithUdpSeamsForTesting(
        serviceName: 'svc',
        daemonHost: 'daemon.example',
        sampling: FixedRateSampler(1.0),
        resolver: (_) async => throw const SocketException('dns down'),
        onSendError: (s, e) => reports.add((segment: s, error: e)),
      );

      final result =
          await tracer.run(tracer.beginSegment(), () async => 'done');

      expect(result, 'done');
      expect(reports, hasLength(1));
      expect(reports.single.error, isA<SocketException>());
    });

    test('every datagram of a split send fails: onSendError still once',
        () async {
      final socket = _FailingSendSocket();
      final reports = <_Report>[];
      final tracer = newTracerWithUdpSeamsForTesting(
        serviceName: 'svc',
        sampling: FixedRateSampler(1.0),
        socketFactory: (_) async => socket,
        onSendError: (s, e) => reports.add((segment: s, error: e)),
      );
      final big = 'x' * 40000;

      final result = await tracer.run(tracer.beginSegment(), () async {
        await tracer.captureAsync('a', (span) async {
          span.addMetadata('blob', big);
        });
        await tracer.captureAsync('b', (span) async {
          span.addMetadata('blob', big);
        });
        return 1;
      });

      expect(result, 1);
      expect(socket.sends, greaterThan(1), reason: 'segment must be split');
      expect(reports, hasLength(1));
    });

    test('a throwing onSendError never faults the app', () async {
      final tracer = newTracerWithUdpSeamsForTesting(
        serviceName: 'svc',
        sampling: FixedRateSampler(1.0),
        socketFactory: (_) async => throw const SocketException('no socket'),
        onSendError: (s, e) => throw StateError('bad hook'),
      );

      expect(await tracer.run(tracer.beginSegment(), () async => 3), 3);
    });

    test('each send reports separately (once per send, not per tracer)',
        () async {
      var calls = 0;
      final tracer = newTracerWithUdpSeamsForTesting(
        serviceName: 'svc',
        sampling: FixedRateSampler(1.0),
        socketFactory: (_) async => throw const SocketException('no socket'),
        onSendError: (s, e) => calls++,
      );

      await tracer.run(tracer.beginSegment(), () async {});
      await tracer.run(tracer.beginSegment(), () async {});

      expect(calls, 2);
    });
  });

  group('concurrent sends are not cross-wired', () {
    test('each concurrent run reports exactly once for its own segment',
        () async {
      final reports = <_Report>[];
      final tracer = newTracerWithUdpSeamsForTesting(
        serviceName: 'svc',
        sampling: FixedRateSampler(1.0),
        socketFactory: (_) async {
          // Suspend so the sends overlap and share the in-flight connect.
          await Future<void>.delayed(Duration.zero);
          throw const SocketException('no socket');
        },
        onSendError: (s, e) => reports.add((segment: s, error: e)),
      );
      final segments = [for (var i = 0; i < 5; i++) tracer.beginSegment()];

      final results = await Future.wait([
        for (var i = 0; i < segments.length; i++)
          tracer.run(segments[i], () async => i),
      ]);

      expect(results, [0, 1, 2, 3, 4]);
      expect(reports, hasLength(segments.length));
      expect(
        reports.map((r) => r.segment.id).toSet(),
        segments.map((s) => s.id).toSet(),
      );
    });
  });

  group('runLambda transport and encode failures', () {
    test('bind failure on runLambda: onSendError once with virtual segment',
        () async {
      final reports = <_Report>[];
      final tracer = newTracerWithUdpSeamsForTesting(
        serviceName: 'lambda-svc',
        sampling: FixedRateSampler(1.0),
        socketFactory: (_) async => throw const SocketException('no socket'),
        onSendError: (s, e) => reports.add((segment: s, error: e)),
      );

      final result =
          await tracer.runLambda(traceId, parentId, 'handler', () async => 7);

      expect(result, 7);
      expect(reports, hasLength(1));
      expect(reports.single.segment.traceId, traceId);
      expect(reports.single.segment.parentId, parentId);
      expect(reports.single.segment.name, 'handler');
      expect(reports.single.error, isA<SocketException>());
    });

    test('cyclic metadata on runLambda: onSendError fires, result returned',
        () async {
      final reports = <_Report>[];
      final tracer = XRayTracer(
        serviceName: 'lambda-svc',
        sender: NoopSender(),
        sampling: FixedRateSampler(1.0),
        onSendError: (s, e) => reports.add((segment: s, error: e)),
      );
      final cyclic = <String, Object>{};
      cyclic['self'] = cyclic;

      final result =
          await tracer.runLambda(traceId, parentId, 'handler', () async {
        tracer.addMetadata('loop', cyclic);
        return 'ok';
      });

      expect(result, 'ok');
      expect(reports, hasLength(1));
      expect(reports.single.segment.traceId, traceId);
    });
  });

  group('user-supplied UdpSender is untouched', () {
    test('its own onError fires; the tracer adds no onSendError report',
        () async {
      final senderErrors = <Object>[];
      var hookCalls = 0;
      final tracer = XRayTracer(
        serviceName: 'svc',
        sender: UdpSender(
          socketFactory: (_) async => throw const SocketException('no socket'),
          onError: senderErrors.add,
        ),
        sampling: FixedRateSampler(1.0),
        onSendError: (s, e) => hookCalls++,
      );

      final result = await tracer.run(tracer.beginSegment(), () async => 5);

      expect(result, 5);
      expect(senderErrors, hasLength(1));
      expect(senderErrors.single, isA<SocketException>());
      expect(hookCalls, 0);
    });
  });
}
