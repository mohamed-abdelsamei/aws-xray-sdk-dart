import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('Subsegment', () {
    test('begin sets inProgress', () {
      final s = Subsegment.begin(name: 'op', namespace: 'aws');
      expect(s.inProgress, isTrue);
      expect(s.endTime, isNull);
    });

    test('close sets endTime', () {
      final s = Subsegment.begin(name: 'op', namespace: 'aws').close();
      expect(s.inProgress, isFalse);
      expect(s.endTime, isNotNull);
    });

    test('applyStatus 5xx sets fault', () {
      final s = Subsegment.begin(name: 'op', namespace: 'aws').applyStatus(500);
      expect(s.fault, isTrue);
    });

    test('applyStatus 429 sets throttle and error', () {
      final s = Subsegment.begin(name: 'op', namespace: 'aws').applyStatus(429);
      expect(s.throttle, isTrue);
      expect(s.error, isTrue);
    });

    test('applyStatus 4xx sets error', () {
      final s = Subsegment.begin(name: 'op', namespace: 'aws').applyStatus(400);
      expect(s.error, isTrue);
      expect(s.fault, isFalse);
    });

    test('toJson omits null optional fields', () {
      final json =
          Subsegment.begin(name: 'op', namespace: 'aws').close().toJson();
      expect(json.containsKey('cause'), isFalse);
      expect(json.containsKey('http'), isFalse);
      expect(json.containsKey('aws'), isFalse);
    });

    test('withFault records cause', () {
      final err = Exception('boom');
      final s = Subsegment.begin(name: 'op', namespace: 'aws').withFault(err);
      expect(s.fault, isTrue);
      expect(s.cause!.exceptions.first.message, contains('boom'));
    });

    test('annotate sanitizes the key and coerces a non-scalar value', () {
      final s = Subsegment.begin(name: 'op', namespace: 'aws')
          .annotate('user name', {'a': 1});
      expect(s.annotations!.containsKey('user name'), isFalse);
      expect(s.annotations!['user_name'], '{a: 1}');
    });

    test('annotate keeps a valid key and scalar value unchanged', () {
      final s =
          Subsegment.begin(name: 'op', namespace: 'aws').annotate('retries', 2);
      expect(s.annotations!['retries'], 2);
    });
  });
}
