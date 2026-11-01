import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:test/test.dart';

class _ThrowingToString {
  @override
  String toString() => throw StateError('toString exploded');
}

class _LongError {
  _LongError(this.text);
  final String text;
  @override
  String toString() => text;
}

const _marker = '…[truncated]';

void main() {
  group('XRayException.from hardening', () {
    test('AC3.3: message over 1024 chars is truncated with marker', () {
      final e = XRayException.from(_LongError('x' * 5000));
      expect(e.message.length, 1024 + _marker.length);
      expect(e.message, endsWith(_marker));
      expect(e.message, startsWith('x' * 1024));
    });

    test('AC3.3: message of exactly 1024 chars is unchanged', () {
      final e = XRayException.from(_LongError('y' * 1024));
      expect(e.message, 'y' * 1024);
    });

    test('AC3.3: truncation does not split a surrogate pair', () {
      // 1023 ASCII chars, then an emoji (2 code units) straddling the cap.
      final e = XRayException.from(_LongError('a' * 1023 + '😀' * 10));
      expect(e.message, 'a' * 1023 + _marker);
    });

    test('AC3.4: throwing toString falls back to the runtime type name', () {
      late XRayException e;
      expect(
          () => e = XRayException.from(_ThrowingToString()), returnsNormally);
      expect(e.type, '_ThrowingToString');
      expect(e.message, '_ThrowingToString');
    });
  });

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
