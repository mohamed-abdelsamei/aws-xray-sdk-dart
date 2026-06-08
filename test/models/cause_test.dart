import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('XRayException', () {
    test('from() captures runtimeType and message', () {
      final e = XRayException.from(FormatException('bad input'));
      expect(e.type, 'FormatException');
      expect(e.message, contains('bad input'));
      expect(e.id, hasLength(16));
      expect(e.remote, isFalse);
    });

    test('toJson omits remote when false', () {
      final json = XRayException.from(Exception('oops')).toJson();
      expect(json.containsKey('remote'), isFalse);
      expect(json['type'], isNotEmpty);
      expect(json['message'], isNotEmpty);
    });

    test('toJson includes remote when true', () {
      const ex = XRayException(
        id: 'abc1234567890123',
        type: 'RemoteError',
        message: 'upstream failed',
        remote: true,
      );
      expect(ex.toJson()['remote'], isTrue);
    });

    test('generated ids are unique', () {
      final ids = List.generate(
        50,
        (_) => XRayException.from(Exception('e')).id,
      );
      expect(ids.toSet().length, greaterThan(40));
    });
  });

  group('Cause', () {
    test('toJson includes exceptions list', () {
      final cause = Cause(
        exceptions: [XRayException.from(Exception('boom'))],
      );
      final json = cause.toJson();
      expect((json['exceptions'] as List), hasLength(1));
    });

    test('empty exceptions list serialises correctly', () {
      final json = const Cause().toJson();
      expect((json['exceptions'] as List), isEmpty);
    });
  });
}
