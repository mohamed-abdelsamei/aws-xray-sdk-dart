import 'dart:convert';

import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:test/test.dart';

class _RecordingSender extends Sender {
  final List<Map<String, Object?>> sent = [];

  @override
  Future<void> send(Segment segment) async {
    sent.add(jsonDecode(jsonEncode(segment.toJson())) as Map<String, Object?>);
  }

  @override
  Future<void> close() async {}

  bool get isEmpty => sent.isEmpty;
  Map<String, Object?> get last => sent.last;
  List get lastSubs => last['subsegments'] as List? ?? const [];
}

void main() {
  late _RecordingSender sender;
  late XRayTracer tracer;

  setUp(() {
    sender = _RecordingSender();
    tracer = XRayTracer(
      serviceName: 'test-svc',
      sender: sender,
      sampling: FixedRateSampler(1.0),
    );
  });

  group('XRayTracer — context', () {
    test('currentSegment is null outside a run()', () {
      expect(tracer.currentSegment, isNull);
    });

    test('currentSegment is set inside run()', () async {
      final segment = tracer.beginSegment();
      Segment? captured;
      await tracer.run(segment, () async {
        captured = tracer.currentSegment;
      });
      expect(captured, isNotNull);
      expect(captured!.name, 'test-svc');
    });

    test('currentSegment propagates across awaits', () async {
      final segment = tracer.beginSegment();
      Segment? inner;
      await tracer.run(segment, () async {
        await Future.delayed(Duration.zero);
        inner = tracer.currentSegment;
      });
      expect(inner, isNotNull);
    });

    test('nested run() calls are independently zoned', () async {
      final seg1 = tracer.beginSegment();
      final seg2 = tracer.beginSegment();
      Segment? captured1;
      Segment? captured2;

      await Future.wait([
        tracer.run(seg1, () async {
          await Future.delayed(const Duration(milliseconds: 10));
          captured1 = tracer.currentSegment;
        }),
        tracer.run(seg2, () async {
          await Future.delayed(const Duration(milliseconds: 10));
          captured2 = tracer.currentSegment;
        }),
      ]);

      expect(captured1!.id, seg1.id);
      expect(captured2!.id, seg2.id);
    });
  });

  group('XRayTracer — subsegments', () {
    test('beginSubsegment / endSubsegment attaches to sent segment', () async {
      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        final sub = tracer.beginSubsegment('my-op', namespace: 'local');
        await Future.delayed(Duration.zero);
        tracer.endSubsegment(sub);
      });

      expect(sender.lastSubs, hasLength(1));
      expect((sender.lastSubs.first as Map)['name'], 'my-op');
    });

    test('failSubsegment records fault on the subsegment', () async {
      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        final sub = tracer.beginSubsegment('failing-op');
        tracer.failSubsegment(sub, Exception('boom'));
      });

      final sub = sender.lastSubs.first as Map;
      expect(sub['fault'], isTrue);
      final cause = sub['cause'] as Map;
      expect((cause['exceptions'] as List).first['message'], contains('boom'));
    });

    test('multiple subsegments all appear in sent segment', () async {
      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        for (final name in ['a', 'b', 'c']) {
          final sub = tracer.beginSubsegment(name);
          tracer.endSubsegment(sub);
        }
      });

      expect(sender.lastSubs, hasLength(3));
      final names = sender.lastSubs.map((s) => (s as Map)['name']).toList();
      expect(names, containsAll(['a', 'b', 'c']));
    });
  });

  group('XRayTracer — segment lifecycle', () {
    test('segment is sent after run() completes', () async {
      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        expect(sender.isEmpty, isTrue); // not yet sent
      });
      expect(sender.sent, hasLength(1));
    });

    test('segment is sent even when run() throws', () async {
      final segment = tracer.beginSegment();
      await expectLater(
        () => tracer.run(segment, () async => throw Exception('fail')),
        throwsException,
      );
      expect(sender.sent, hasLength(1));
    });

    test('sent segment has end_time and no in_progress', () async {
      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {});
      expect(sender.last.containsKey('end_time'), isTrue);
      expect(sender.last.containsKey('in_progress'), isFalse);
    });

    test('beginSegment uses tracer serviceName', () {
      final seg = tracer.beginSegment();
      expect(seg.name, 'test-svc');
    });

    test('beginSegment generates unique trace IDs', () {
      final ids =
          List.generate(20, (_) => tracer.beginSegment().traceId.toString());
      expect(ids.toSet(), hasLength(20));
    });
  });

  group('XRayTracer — sampling', () {
    test('segments are not sent when sampling rate is 0', () async {
      final neverTracer = XRayTracer(
        serviceName: 'svc',
        sender: sender,
        sampling: FixedRateSampler(0.0),
      );
      final segment = neverTracer.beginSegment();
      await neverTracer.run(segment, () async {});
      expect(sender.isEmpty, isTrue);
    });

    test('segments are always sent when sampling rate is 1', () async {
      for (var i = 0; i < 5; i++) {
        final seg = tracer.beginSegment();
        await tracer.run(seg, () async {});
      }
      expect(sender.sent, hasLength(5));
    });
  });
}
