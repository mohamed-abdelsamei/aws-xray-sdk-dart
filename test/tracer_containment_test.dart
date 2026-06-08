import 'dart:convert';

import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:test/test.dart';

/// A Sender whose transport operations always throw — stands in for any
/// arbitrary Sender failure (the guarantee is sender-agnostic).
class _ThrowingSender extends Sender {
  @override
  Future<void> send(Segment segment) async => throw StateError('send boom');

  @override
  Future<void> sendPackets(List<List<int>> packets) async =>
      throw StateError('packets boom');

  @override
  Future<void> close() async {}
}

/// Counts send invocations and records the last segment (to assert sampling
/// skip and that fault-on-uncaught survives containment).
class _CountingSender extends Sender {
  int sendCount = 0;
  Map<String, Object?>? last;

  @override
  Future<void> send(Segment segment) async {
    sendCount++;
    last = jsonDecode(jsonEncode(segment.toJson())) as Map<String, Object?>;
  }

  @override
  Future<void> close() async {}
}

void main() {
  final traceId = TraceId.generate();
  const parentId = 'abcdef1234567890';

  XRayTracer tracerWith(Sender sender, {double rate = 1.0}) => XRayTracer(
        serviceName: 'svc',
        sender: sender,
        sampling: FixedRateSampler(rate),
      );

  group('Tracer transport containment — run()', () {
    test('a sender throw does not escape; fn result is preserved', () async {
      final tracer = tracerWith(_ThrowingSender());
      final result = await tracer.run(tracer.beginSegment(), () async => 'ok');
      expect(result, 'ok');
    });

    test('fn original exception propagates, not the sender error', () async {
      final tracer = tracerWith(_ThrowingSender());
      await expectLater(
        () => tracer.run(
          tracer.beginSegment(),
          () async => throw const FormatException('real failure'),
        ),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', 'real failure')),
      );
    });
  });

  group('Tracer transport containment — runLambda()', () {
    test('a sender throw does not escape; fn result is preserved', () async {
      final tracer = tracerWith(_ThrowingSender());
      final result = await tracer.runLambda(
        traceId,
        parentId,
        'handler',
        () async => 42,
      );
      expect(result, 42);
    });

    test('fn original exception propagates, not the sender error', () async {
      final tracer = tracerWith(_ThrowingSender());
      await expectLater(
        () => tracer.runLambda(
          traceId,
          parentId,
          'handler',
          () async => throw const FormatException('real failure'),
        ),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', 'real failure')),
      );
    });
  });

  group('Tracer transport containment — narrowness', () {
    test('fn errors still propagate (a non-throwing sender)', () async {
      final tracer = tracerWith(_CountingSender());
      await expectLater(
        () => tracer.run(
            tracer.beginSegment(), () async => throw StateError('x')),
        throwsStateError,
      );
    });

    test('unsampled trace does not call the sender', () async {
      final sender = _CountingSender();
      final tracer = tracerWith(sender, rate: 0.0);
      await tracer.run(tracer.beginSegment(), () async {});
      expect(sender.sendCount, 0);
    });

    test('fault-on-uncaught is preserved under containment', () async {
      final sender = _CountingSender();
      final tracer = tracerWith(sender);
      await expectLater(
        () => tracer.run(
            tracer.beginSegment(), () async => throw Exception('boom')),
        throwsException,
      );
      expect(sender.sendCount, 1);
      expect(sender.last!['fault'], isTrue);
    });
  });

  group('Tracer transport containment — close()', () {
    test('tracer.close() does not surface a throwing Sender.close()', () async {
      final tracer = tracerWith(_ThrowingCloseSender());
      await expectLater(tracer.close(), completes);
    });
  });

  group('Tracer transport containment — closeSegment()', () {
    test('direct closeSegment() does not surface a throwing Sender.send()',
        () async {
      final tracer = tracerWith(_ThrowingSender());
      final segment = tracer.beginSegment().close();
      await expectLater(tracer.closeSegment(segment), completes);
    });
  });

  group('Tracer transport containment — serialization failures', () {
    // A non-JSON-encodable annotation value makes serialization throw during
    // finalization — for runLambda this is inside encodeSubsegmentDoc, upstream
    // of the sender; for run it is inside the sender's encode step. Both must be
    // contained.
    test('run(): a finalization serialization failure is contained', () async {
      final tracer = tracerWith(_CountingSender());
      final result = await tracer.run(tracer.beginSegment(), () async {
        tracer.addMetadata('bad', Object()); // not JSON-encodable
        return 'ok';
      });
      expect(result, 'ok');
    });

    test('runLambda(): an encode failure upstream of the sender is contained',
        () async {
      final tracer = tracerWith(_PacketSender());
      final result =
          await tracer.runLambda(traceId, parentId, 'handler', () async {
        tracer.addMetadata('bad', Object()); // not JSON-encodable
        return 'ok';
      });
      expect(result, 'ok');
    });
  });
}

/// Captures raw packets (used by runLambda) without throwing.
class _PacketSender extends Sender {
  final List<List<int>> packets = [];

  @override
  Future<void> send(Segment segment) async {}

  @override
  Future<void> sendPackets(List<List<int>> ps) async => packets.addAll(ps);

  @override
  Future<void> close() async {}
}

/// A Sender whose close() throws — verifies shutdown never faults on transport.
class _ThrowingCloseSender extends Sender {
  @override
  Future<void> send(Segment segment) async {}

  @override
  Future<void> close() async => throw StateError('close boom');
}
