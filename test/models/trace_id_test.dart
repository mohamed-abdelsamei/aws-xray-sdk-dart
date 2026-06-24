import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('TraceId', () {
    test('generate produces valid format', () {
      final id = TraceId.generate().toString();
      final parts = id.split('-');
      expect(parts, hasLength(3));
      expect(parts[0], '1');
      expect(parts[1], hasLength(8));
      expect(parts[2], hasLength(24));
    });

    test('generate produces unique IDs', () {
      final ids = List.generate(100, (_) => TraceId.generate().toString());
      expect(ids.toSet(), hasLength(100));
    });

    test('tryParse returns null for invalid input', () {
      expect(TraceId.tryParse(''), isNull);
      expect(TraceId.tryParse('Root=bad'), isNull);
      expect(TraceId.tryParse('2-abc-def'), isNull);
    });

    test('tryParse roundtrips a generated ID', () {
      final id = TraceId.generate();
      final header = 'Root=$id;Parent=abc123;Sampled=1';
      final parsed = TraceId.tryParse(header);
      expect(parsed?.toString(), id.toString());
    });

    test('parseParentId extracts Parent field', () {
      const header = 'Root=1-abc-def;Parent=parentid123;Sampled=1';
      expect(TraceId.parseParentId(header), 'parentid123');
    });

    test('parseSampled returns true for Sampled=1', () {
      expect(TraceId.parseSampled('Root=1-abc-def;Sampled=1'), isTrue);
      expect(TraceId.parseSampled('Root=1-abc-def;Sampled=0'), isFalse);
      expect(TraceId.parseSampled('Root=1-abc-def'), isNull);
    });

    test('parseRootString returns the Root id string', () {
      final id = TraceId.generate();
      final header = 'Root=$id;Parent=abc123;Sampled=1';
      expect(TraceId.parseRootString(header), id.toString());
    });

    test('parseRootString returns null for an invalid header', () {
      expect(TraceId.parseRootString(''), isNull);
      expect(TraceId.parseRootString('Parent=abc;Sampled=1'), isNull);
      expect(TraceId.parseRootString('Root=bad'), isNull);
    });
  });
}
