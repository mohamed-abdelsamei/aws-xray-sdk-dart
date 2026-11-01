import 'dart:io';

import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:http/http.dart' as http;
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
    test('message over 1024 chars is truncated with marker', () {
      final e = XRayException.from(_LongError('x' * 5000));
      expect(e.message.length, 1024 + _marker.length);
      expect(e.message, endsWith(_marker));
      expect(e.message, startsWith('x' * 1024));
    });

    test('message of exactly 1024 chars is unchanged', () {
      final e = XRayException.from(_LongError('y' * 1024));
      expect(e.message, 'y' * 1024);
    });

    test('truncation does not split a surrogate pair', () {
      // 1023 ASCII chars, then an emoji (2 code units) straddling the cap.
      final e = XRayException.from(_LongError('a' * 1023 + '😀' * 10));
      expect(e.message, 'a' * 1023 + _marker);
    });

    test('throwing toString falls back to the runtime type name', () {
      late XRayException e;
      expect(
          () => e = XRayException.from(_ThrowingToString()), returnsNormally);
      expect(e.type, '_ThrowingToString');
      expect(e.message, '_ThrowingToString');
    });
  });

  group('URLs in exception messages', () {
    String m(String text) =>
        XRayException.from(_LongError(text)).toJson()['message'] as String;

    test('real package:http and dart:io errors lose userinfo, query, fragment',
        () {
      final uri =
          Uri.parse('https://u:pw@h.example/p?X-Amz-Signature=abc#frag');
      for (final error in [
        http.ClientException('Connection failed', uri),
        HttpException('Connection closed', uri: uri),
      ]) {
        final message = XRayException.from(error).message;
        expect(message, contains('https://h.example/p'));
        for (final secret in ['u:pw', '@', 'X-Amz', 'abc', 'frag']) {
          expect(message, isNot(contains(secret)), reason: message);
        }
      }
    });

    test('a URL straddling the cap is redacted before truncation', () {
      final input = '${'a' * 1005} https://user:secretpw@h/p';
      expect(m(input), '${'a' * 1005} https://h/p');
      expect(XRayException.from(_LongError(input)).message,
          '${'a' * 1005} https://h/p');
    });

    test('a long URL message is redacted, then truncated', () {
      final input = '${'a' * 1010} '
          'https://user:secretpw@h.example/p?X-Amz-Signature=${'S' * 200}';
      final out = m(input);
      expect(out.length, lessThanOrEqualTo(1024 + _marker.length));
      expect(out, endsWith(_marker));
      for (final secret in ['user', 'secret', 'X-Amz', 'SSS']) {
        expect(out, isNot(contains(secret)));
      }
    });

    test('user-built exceptions are redacted in toJson only', () {
      const raw = 'GET https://u:p@h.example/p?sig=abc failed';
      const e = XRayException(id: 'x', type: 'T', message: raw);
      expect(e.toJson()['message'], 'GET https://h.example/p failed');
      expect(e.message, raw);
    });

    test('toJson does not truncate user-built messages', () {
      final e = XRayException(id: 'x', type: 'T', message: 'z' * 3000);
      expect(e.toJson()['message'], 'z' * 3000);
    });

    test('toJson leaves messages built by from() unchanged', () {
      for (final text in [
        'ClientException: Connection failed, uri=https://b.s3.amazonaws.com/k'
            '?X-Amz-Signature=abc123',
        'GET https://u:p@a.example/x?t=1 -> 302 https://b.example/y#frag',
        '${'a' * 1005} https://user:secretpw@h/p',
        '${'a' * 1010} https://user:pw@h.example/p?s=${'S' * 200}',
        '${'a' * 1015} https://h.example:8443/very/long/path',
        '${'a' * 1018} https://[::1]:8080/p',
        '${'a' * 1020} https://u@/x@y',
        r'0https://u:p@h.example\p?x',
        'ratio 1:2 at 12:30',
        '\uD800 https://h/\uDC00?x',
        'x' * 5000,
      ]) {
        final e = XRayException.from(_LongError(text));
        expect(e.toJson()['message'], e.message, reason: text);
      }
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
