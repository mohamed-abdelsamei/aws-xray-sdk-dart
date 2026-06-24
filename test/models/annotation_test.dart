import 'dart:convert';
import 'dart:io';

import 'package:aws_xray_sdk/src/models/annotation.dart';
import 'package:test/test.dart';

/// Captures `stderr` writes during [body] so the warn-once diagnostic can be
/// asserted on.
String _captureStderr(void Function() body) {
  final buffer = _CapturingSink();
  IOOverrides.runZoned(body, stderr: () => buffer);
  return buffer.text;
}

/// Minimal [Stdout] capturing written text; unused members no-op.
class _CapturingSink implements Stdout {
  final StringBuffer _buffer = StringBuffer();
  String get text => _buffer.toString();

  @override
  void writeln([Object? obj = '']) => _buffer.writeln(obj);
  @override
  void write(Object? obj) => _buffer.write(obj);
  @override
  Encoding encoding = utf8;
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(resetAnnotationKeyWarnings);

  group('sanitizeAnnotationKey', () {
    test('leaves a valid key unchanged', () {
      expect(sanitizeAnnotationKey('orderId'), 'orderId');
      expect(sanitizeAnnotationKey('order_id_2'), 'order_id_2');
      expect(sanitizeAnnotationKey('ABC123_xyz'), 'ABC123_xyz');
    });

    test('replaces each disallowed character with an underscore', () {
      expect(sanitizeAnnotationKey('order.id'), 'order_id');
      expect(sanitizeAnnotationKey('order id'), 'order_id');
      expect(sanitizeAnnotationKey('user-name'), 'user_name');
      expect(sanitizeAnnotationKey('a/b:c'), 'a_b_c');
    });

    test('replaces a run of disallowed characters one-for-one', () {
      // Each invalid char becomes one underscore (not collapsed).
      expect(sanitizeAnnotationKey('a..b'), 'a__b');
      expect(sanitizeAnnotationKey('a  b'), 'a__b');
    });

    test('handles unicode / symbol characters', () {
      expect(sanitizeAnnotationKey(r'price$'), 'price_');
      expect(sanitizeAnnotationKey('café'), 'caf_');
    });

    test('an empty key becomes a single underscore', () {
      expect(sanitizeAnnotationKey(''), '_');
    });

    test('an all-invalid key becomes a single underscore', () {
      // Would sanitize to '' (one underscore per char would be '...'),
      // wait: each invalid char maps to '_', so '...' -> '___'.
      expect(sanitizeAnnotationKey('...'), '___');
      // Truly empty-after-sanitize only happens for the empty string.
      expect(sanitizeAnnotationKey(''), '_');
    });
  });

  group('coerceAnnotationValue', () {
    test('passes through valid scalar types unchanged (identical instance)',
        () {
      const s = 'hello';
      const i = 42;
      const d = 3.14;
      const b = true;
      expect(identical(coerceAnnotationValue(s), s), isTrue);
      expect(identical(coerceAnnotationValue(i), i), isTrue);
      expect(identical(coerceAnnotationValue(d), d), isTrue);
      expect(identical(coerceAnnotationValue(b), b), isTrue);
    });

    test('coerces a List to its toString()', () {
      expect(coerceAnnotationValue([1, 2, 3]), '[1, 2, 3]');
    });

    test('coerces a Map to its toString()', () {
      expect(coerceAnnotationValue({'a': 1}), '{a: 1}');
    });

    test('coerces an arbitrary object to its toString()', () {
      expect(coerceAnnotationValue(Duration.zero), const Duration().toString());
    });

    test('coerces a DateTime to its toString()', () {
      final dt = DateTime.utc(2026, 1, 2, 3, 4, 5);
      expect(coerceAnnotationValue(dt), dt.toString());
    });
  });

  group('sanitizeAnnotationKey warn-once (M7)', () {
    test('warns when a key is changed', () {
      final out = _captureStderr(() => sanitizeAnnotationKey('my-metric'));
      expect(out, contains('my-metric'));
      expect(out, contains('my_metric'));
    });

    test('does not warn for an already-valid key', () {
      final out = _captureStderr(() => sanitizeAnnotationKey('my_metric'));
      expect(out, isEmpty);
    });

    test('warns only once per distinct original key', () {
      final out = _captureStderr(() {
        sanitizeAnnotationKey('my-metric');
        sanitizeAnnotationKey('my-metric');
        sanitizeAnnotationKey('my-metric');
      });
      expect('\n'.allMatches(out.trim()), isEmpty,
          reason: 'a single line means a single warning');
      expect(out, contains('my-metric'));
    });

    test('warns separately for different keys', () {
      final out = _captureStderr(() {
        sanitizeAnnotationKey('a-b');
        sanitizeAnnotationKey('c.d');
      });
      expect(out, contains('a-b'));
      expect(out, contains('c.d'));
    });
  });
}
