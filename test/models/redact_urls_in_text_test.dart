// ignore: implementation_imports
import 'package:aws_xray_sdk/src/models/http_data.dart'
    show redactUrl, redactUrlsInText;
import 'dart:math';

import 'package:test/test.dart';

const r = redactUrlsInText;

/// Every non-timing input below, for the idempotence check.
final _corpus = <String>[];

void _exact(String input, String expected) {
  _corpus.add(input);
  expect(r(input), expected, reason: 'input: $input');
}

void _noLeak(String input, List<String> secrets) {
  _corpus.add(input);
  final out = r(input);
  for (final s in secrets) {
    expect(out, isNot(contains(s)), reason: 'input: $input -> $out');
  }
}

String _repeatTo(String unit, int length) {
  final b = StringBuffer();
  while (b.length < length) {
    b.write(unit);
  }
  return b.toString().substring(0, length);
}

void main() {
  group('redactUrlsInText', () {
    test('package:http ClientException', () {
      _exact(
        'ClientException: Connection failed, uri=https://b.s3.amazonaws.com/k'
            '?X-Amz-Signature=abc123&X-Amz-Credential=AKIAEXAMPLE',
        'ClientException: Connection failed, uri=https://b.s3.amazonaws.com/k',
      );
    });

    test('dart:io HttpException', () {
      _exact(
        'HttpException: Connection closed before full header was received, '
            'uri = https://u:pw@h.example/p#frag',
        'HttpException: Connection closed before full header was received, '
            'uri = https://h.example/p',
      );
    });

    group('adversarial shapes', () {
      test('an @ in the query or fragment of a URL with no path', () {
        _exact(
          'ClientException: Connection failed, '
              'uri=https://api.example.com?email=a@b.com&token=SECRET',
          'ClientException: Connection failed, uri=https://api.example.com',
        );
        _exact('https://h#a@b.c&token=SECRET', 'https://h');
        _exact('https://h:443?e=a@b&token=SECRET', 'https://h:443');
        _exact('https://[::1]:8080?e=a@b&t=S', 'https://[::1]:8080');
        _exact('see https://h?e=a@b/c&token=SECRET now', 'see https://h now');
        _exact('https://u@h?e=a@b&token=SECRET', 'https://');
        _exact('https://u:p?ss@h/p', 'https://');
        _exact('https://u:p#ss@h/p', 'https://');
        _exact('https://u:123?ss@h/p', 'https://u:123');
      });

      const secrets = ['u:p', 'pw', 'abc', 'sig', 'frag', '@'];

      test('uppercase scheme', () {
        _exact('HTTPS://U:P@H.EXAMPLE/X?SIG=1', 'HTTPS://H.EXAMPLE/X');
      });

      test('backslashes and JSON-escaped slashes', () {
        _exact(r'https:\\u:p@h.example\p?sig=abc', r'https:\\h.example\p');
        _exact(
          r'https:\/\/h.example\/p?X-Amz-Signature=abc',
          r'https:\/\/h.example\/p',
        );
        _noLeak(r'https:\/\/u:p@h.example\/p', secrets);
      });

      test('quotes and parens', () {
        _exact(
          "failed: 'https://h.example/p?sig=abc'",
          "failed: 'https://h.example/p",
        );
        _exact('(https://u:p@h.example/p)', '(https://h.example/p)');
        _exact('"https://u:p@h.example/p"', '"https://h.example/p"');
        _exact('<https://u:p@h.example/p>', '<https://h.example/p>');
      });

      test('multiple URLs', () {
        _exact(
          'GET https://u:p@a.example/x?t=1 -> 302 https://b.example/y#frag '
              '(via proxy http://p:q@c.example:8080/)',
          'GET https://a.example/x -> 302 https://b.example/y '
              '(via proxy http://c.example:8080/)',
        );
      });

      test('separators inside the password', () {
        for (final input in [
          'https://u:p?w#x/y@h.example/p?sig=abc',
          'https://u:p/x\\y@h.example/p',
          'https://u:p:/q@h.example/p',
          'https://u:p://q@h.example/p',
          'https://u:p?x@h.example/p',
          'https://u:p#x@h.example/p',
          'https://u:p@x@h.example/p',
        ]) {
          _noLeak(input, ['p?w', 'x/y', 'abc', 'u:p', 'p:', '@']);
        }
      });

      test('odd or empty scheme', () {
        for (final input in [
          '0https://u:p@h.example/p',
          'x-y+z.1://u:p@h.example/p',
          '=://u:p@h.example/p',
          'see ://u:p@h.example/p',
          '://u:p@h.example/p',
          '-://u:p@h.example/p',
          'é://u:p@h.example/p',
        ]) {
          _noLeak(input, ['u:p', '@']);
        }
        _exact('0https://u:p@h.example/p', '0https://h.example/p');
        _exact('=://u:p@h.example/p', '=://h.example/p');
      });

      test('non-ASCII whitespace inside userinfo', () {
        _noLeak('https://u:p\u00A0w@h.example/p', ['u:p', '\u00A0w']);
        _noLeak('https://u:p\u2028w@h.example/p', ['u:p', '\u2028w']);
        _noLeak('https://u:p\u3000w@h.example/p?sig=1', ['u:p', 'sig']);
      });

      test('control characters before the URL', () {
        _exact(
          'uri=\thttps://u:p@h.example/p?sig=abc',
          'uri=\thttps://h.example/p',
        );
        _exact('\x00https://u:p@h.example/p', '\x00https://h.example/p');
        _exact('a\r\n\x1fhttps://u:p@h/p', 'a\r\n\x1fhttps://h/p');
      });

      test('URL nested in a path or query of another URL', () {
        _noLeak('https://proxy.example/https://u:p@t.example/x', secrets);
        _noLeak('https://a.example/x->https://u:p@b.example/y', secrets);
        _noLeak('https://h.example/r?next=https://u:p@b.example/y', secrets);
        _noLeak('https://u:p@a.example/https://v:q@b.example/', [
          'u:p',
          'v:q',
          '@',
        ]);
        _exact(
          'https://a.example/x->https://u:p@b.example/y?sig=abc',
          'https://a.example/x->https://b.example/y',
        );
      });

      test('host with a trailing colon before the path', () {
        _exact('https://h:/u:p@x/', 'https://h:/x/');
        _exact('https://u:p@h:/x', 'https://h:/x');
      });

      test('encoded forms are not decoded (kept or dropped, never leaked)', () {
        // An encoded `@` in userinfo is not userinfo to X-Ray's parser either;
        // the query is still dropped.
        _noLeak('https://h.example/p%3Fsig%3Dabc?sig=abc', ['sig=']);
        _exact('https%3A%2F%2Fu%3Ap%40h', 'https%3A%2F%2Fu%3Ap%40h');
      });
    });

    test('single tokens match redactUrl exactly', () {
      for (final url in [
        'https://user:pw@h.example/p?X-Amz-Signature=abc#f',
        'https://h.example:8443/a/b?x=1',
        'http://user@h.example:80/p',
        'https://u:p@ss@h.example/p',
        'https://h.example/p@q/r?t=1',
        'https://[::1]:8080/p?a=1',
        'https://u:p/x@h.example/p',
        'https://u:p?x/y@h/p',
        'https://h.example/p#frag?notquery',
        r'https:\\u:p@h\p',
        'https:///u:p@h/p',
        'https://',
        'https://[',
      ]) {
        _corpus.add(url);
        expect(r(url), redactUrl(url), reason: url);
      }
    });

    test('non-URL text is unchanged', () {
      for (final input in [
        '',
        'Error: timeout after 30s',
        'ratio 1:2 at 12:30',
        'path /tmp/a?b#c@d',
        'mailto:a@b.c?x',
        'user@example.com said: hi?',
        'a:b:c',
        '日本語 😀',
        _repeatTo('abc def?#@ 1:2 ', 2000),
      ]) {
        _exact(input, input);
        expect(identical(r(input), input) || r(input) == input, isTrue);
      }
    });

    test('never throws on degenerate input', () {
      final inputs = [
        '\uD800',
        '\uDC00',
        'https://\uD800@h/\uDC00?x',
        '\uDC00:/\uD800',
        ':/' * 10000,
        '::::////',
        'a:' * 500000,
        'https://${'@' * 10000}',
        'https://[${':' * 10000}',
        String.fromCharCodes(List.generate(0x21, (i) => i)),
        ':',
        ':/',
        r':\',
        'a:/?',
        'a:/#',
        'a:/@',
      ];
      for (final input in inputs) {
        _corpus.add(input);
        expect(() => r(input), returnsNormally);
      }
      expect(r('https://${'@' * 10000}'), 'https://');
    });

    test('1 MiB inputs complete in under 1 s each', () {
      const n = 1 << 20;
      for (final unit in [
        'a',
        'a:',
        'a://',
        'https://u:p@h/',
        ':/',
        'a:/[',
        'h://u@/',
        ':/@',
        'h://x:y/',
      ]) {
        final input = _repeatTo(unit, n);
        final sw = Stopwatch()..start();
        final out = r(input);
        sw.stop();
        expect(sw.elapsedMilliseconds, lessThan(1000), reason: unit);
        if (unit.contains('@')) expect(out, isNot(contains('u:p')));
      }
    });

    test('URL straddling 1024 is fully redacted (redaction is untruncated)',
        () {
      final input = '${'a' * 1015} https://user:secretpw@h.example/p?s=1';
      expect(r(input), '${'a' * 1015} https://h.example/p');
    });

    test('seeded fuzz: idempotent, and an embedded secret never survives', () {
      final rnd = Random(1);
      const alphabet = 'aZ1:/\\@?#.[] \t\u00A0%';
      for (var k = 0; k < 50000; k++) {
        final s = String.fromCharCodes(List.generate(
          rnd.nextInt(16),
          (_) => alphabet.codeUnitAt(rnd.nextInt(alphabet.length)),
        ));
        final once = r(s);
        expect(r(once), once, reason: 'input: $s');
        if (s.contains(RegExp(r'[\x00-\x20]'))) continue;
        final out = r('x ${s}https://SEC:RET@h/$s?SIG');
        expect(out, isNot(matches(RegExp('SEC|RET|SIG'))), reason: s);
        // An `@` in the query or fragment of a URL, with or without a path.
        for (final mark in ['?', '#']) {
          final url = 'https://h$s${mark}e=a@b$s&token=SECRET';
          for (final o in [r('x $url'), redactUrl(url)]) {
            expect(o, isNot(contains('SECRET')), reason: url);
          }
        }
      }
    });

    test('idempotent on the whole corpus', () {
      expect(_corpus, isNotEmpty);
      for (final input in _corpus) {
        final once = r(input);
        expect(r(once), once, reason: 'input: $input');
      }
    });
  });
}
