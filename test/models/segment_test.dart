import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:test/test.dart';

void main() {
  final traceId = TraceId.generate();

  Segment makeSegment() =>
      Segment.begin(name: 'test-service', traceId: traceId);

  group('Segment', () {
    test('begin sets inProgress and no endTime', () {
      final s = makeSegment();
      expect(s.inProgress, isTrue);
      expect(s.endTime, isNull);
    });

    test('close sets endTime and clears inProgress', () {
      final s = makeSegment().close();
      expect(s.inProgress, isFalse);
      expect(s.endTime, isNotNull);
    });

    test('withFault / withError / withThrottle flags', () {
      expect(makeSegment().withFault().fault, isTrue);
      expect(makeSegment().withError().error, isTrue);
      final t = makeSegment().withThrottle();
      expect(t.throttle, isTrue);
      expect(t.error, isTrue);
    });

    test('addSubsegment appends to subsegments list', () {
      final sub = Subsegment.begin(name: 'op', namespace: 'aws').close();
      final s = makeSegment().addSubsegment(sub);
      expect(s.subsegments, hasLength(1));
    });

    test('toJson includes required fields', () {
      final json = makeSegment().close().toJson();
      expect(json['trace_id'], traceId.toString());
      expect(json['name'], 'test-service');
      expect(json.containsKey('end_time'), isTrue);
      expect(json.containsKey('in_progress'), isFalse);
    });

    test('annotate stores annotation', () {
      final s = makeSegment().annotate('key', 'value');
      expect((s.annotations!['key']), 'value');
    });

    test('close is idempotent', () {
      final s = makeSegment().close();
      expect(s.close().endTime, s.endTime);
    });

    test('namespace is null by default', () {
      expect(makeSegment().namespace, isNull);
    });

    test('namespace is settable via begin', () {
      final s = Segment.begin(
        name: 'svc',
        traceId: traceId,
        namespace: 'remote',
      );
      expect(s.namespace, 'remote');
    });

    test('namespace is null by default when not provided', () {
      final s = Segment.begin(name: 'svc', traceId: traceId);
      expect(s.namespace, isNull);
    });

    test('toJson omits namespace when null', () {
      final json = makeSegment().close().toJson();
      expect(json.containsKey('namespace'), isFalse);
    });

    test('toJson includes namespace when set', () {
      final s = Segment.begin(
        name: 'svc',
        traceId: traceId,
        namespace: 'aws',
      ).close();
      final json = s.toJson();
      expect(json['namespace'], 'aws');
    });

    test('withFault with error records cause', () {
      final s = makeSegment().withFault(Exception('crash'));
      expect(s.fault, isTrue);
      expect(s.cause, isNotNull);
      expect(s.cause!.exceptions.first.message, contains('crash'));
    });

    test('withError with error records cause', () {
      final s = makeSegment().withError(Exception('bad'));
      expect(s.error, isTrue);
      expect(s.cause, isNotNull);
      expect(s.cause!.exceptions.first.message, contains('bad'));
    });
  });
}
