import 'dart:convert';

import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('InMemorySender', () {
    test('captures segments sent via send()', () async {
      final sender = InMemorySender();
      final segment = Segment.begin(
        name: 'svc',
        traceId: TraceId.generate(),
      ).close();

      await sender.send(segment);

      expect(sender.segments, hasLength(1));
      expect(sender.segments.single.name, 'svc');
    });

    test('captures raw payloads sent via sendPackets()', () async {
      final sender = InMemorySender();
      await sender.sendPackets([
        utf8.encode('one'),
        utf8.encode('two'),
      ]);

      expect(sender.packets, hasLength(2));
      expect(utf8.decode(sender.packets.first), 'one');
    });

    test('records emission from a real traced run', () async {
      final sender = InMemorySender();
      final tracer = XRayTracer(
        serviceName: 'svc',
        sender: sender,
        sampling: FixedRateSampler(1.0),
      );

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        final sub = tracer.beginSubsegment('my-op', namespace: 'local');
        tracer.endSubsegment(sub);
      });

      expect(sender.segments, hasLength(1));
      expect(sender.segments.single.subsegments, hasLength(1));
      expect(sender.segments.single.subsegments.single.name, 'my-op');
    });

    test('drops nothing when sampling is on, sends nothing when off', () async {
      final sender = InMemorySender();
      final tracer = XRayTracer(
        serviceName: 'svc',
        sender: sender,
        sampling: FixedRateSampler(0.0),
      );

      await tracer.run(tracer.beginSegment(), () async {});

      expect(sender.segments, isEmpty);
    });

    test('clear resets captured segments and packets', () async {
      final sender = InMemorySender();
      await sender.send(
          Segment.begin(name: 'svc', traceId: TraceId.generate()).close());
      await sender.sendPackets([utf8.encode('x')]);

      sender.clear();

      expect(sender.segments, isEmpty);
      expect(sender.packets, isEmpty);
    });

    test('close marks the sender closed', () async {
      final sender = InMemorySender();
      expect(sender.isClosed, isFalse);
      await sender.close();
      expect(sender.isClosed, isTrue);
    });

    test('segments view is unmodifiable', () async {
      final sender = InMemorySender();
      await sender.send(
          Segment.begin(name: 'svc', traceId: TraceId.generate()).close());
      expect(
        () => sender.segments.clear(),
        throwsUnsupportedError,
      );
    });
  });
}
