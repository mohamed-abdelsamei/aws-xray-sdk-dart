import 'package:aws_xray_sdk/aws_xray_sdk.dart';
// ignore: implementation_imports
import 'package:aws_xray_sdk/src/models/http_data.dart' show redactUrl;
import 'package:test/test.dart';

void main() {
  group('redactUrl (ADR 0001)', () {
    const cases = <String, String>{
      // AC3.1: userinfo, query, and fragment all removed.
      'https://user:pw@h.example/p?X-Amz-Signature=abc#f':
          'https://h.example/p',
      'https://h.example/p': 'https://h.example/p',
      'https://h.example': 'https://h.example',
      'https://h.example:8443/a/b?x=1': 'https://h.example:8443/a/b',
      'http://user@h.example:80/p': 'http://h.example:80/p',
      'https://u:p@ss@h.example/p': 'https://h.example/p',
      'https://h.example/p@q/r?t=1': 'https://h.example/p@q/r',
      'https://[::1]:8080/p?a=1': 'https://[::1]:8080/p',
      'https://h.example/p#frag?notquery': 'https://h.example/p',
      'https://h.example/a%20b?x': 'https://h.example/a%20b',
      '//user:pw@h.example/p?q': '//h.example/p',
      '/relative/path?token=x': '/relative/path',
      '': '',
      '?only=query': '',
      '/users/a@b.com': '/users/a@b.com',
      'mailto:a@b.com': 'mailto:a@b.com',
      // Credentials hidden behind ?, #, /, or \ are still stripped.
      'https://u:p?ss@h/p': 'https://h/p',
      'https://u:p#ss@h/p': 'https://h/p',
      'https://u:pa/ss@h/p': 'https://h/p',
      r'https:\\u:p@h/p': r'https:\\h/p',
      'u:p@host/p?x': 'host/p',
      ' https://u:p@h/p': 'https://h/p',
      '\thttps://u:p@h/p': 'https://h/p',
      'https:/u:p@h/p': 'https:/h/p',
      'https:///u:p@h/p': 'https:///h/p',
      'https://h/p/a@b/c': 'https://h/p/a@b/c',
      // RFC 3986 reads this as host `u`, port 123, path `/x@h/p`: a valid
      // authority, so it is kept as is.
      'https://u:123/x@h/p': 'https://u:123/x@h/p',
      // AC3.2: strings Uri.tryParse rejects are still cut at the first ?/#.
      'http://[bad/p?secret=1': 'http://[bad/p',
      'http://user:pw@h:abc/p?secret=1#f': 'http://h:abc/p',
      'ht tp://h/?secret=1': 'ht tp://h/',
    };
    cases.forEach((input, expected) {
      test('${input.isEmpty ? '(empty)' : input} -> $expected', () {
        expect(redactUrl(input), expected);
      });
    });

    test('AC3.2 fixtures really are rejected by Uri.tryParse', () {
      expect(Uri.tryParse('http://[bad/p?secret=1'), isNull);
      expect(Uri.tryParse('http://user:pw@h:abc/p?secret=1#f'), isNull);
      expect(Uri.tryParse('ht tp://h/?secret=1'), isNull);
    });
  });

  group('HttpRequestData', () {
    test('toJson includes required fields', () {
      const req = HttpRequestData(method: 'GET', url: 'https://example.com');
      final json = req.toJson();
      expect(json['method'], 'GET');
      expect(json['url'], 'https://example.com');
    });

    test('toJson contains only method and url when traced is omitted', () {
      const req = HttpRequestData(method: 'POST', url: 'https://example.com');
      expect(req.toJson().keys, unorderedEquals(['method', 'url']));
    });

    test('toJson emits the redacted url; the model keeps the raw value', () {
      const raw = 'https://user:pw@h.example/p?X-Amz-Signature=abc#f';
      const req = HttpRequestData(method: 'GET', url: raw);
      expect(req.url, raw);
      expect(req.toJson()['url'], 'https://h.example/p');
    });

    test('toJson includes traced when set', () {
      const req = HttpRequestData(
        method: 'POST',
        url: 'https://example.com',
        traced: true,
      );
      expect(req.toJson()['traced'], isTrue);
    });
  });

  group('HttpResponseData', () {
    test('toJson includes status', () {
      const res = HttpResponseData(status: 200);
      expect(res.toJson()['status'], 200);
    });

    test('toJson omits content_length when null', () {
      const res = HttpResponseData(status: 404);
      expect(res.toJson().containsKey('content_length'), isFalse);
    });

    test('toJson includes content_length when set', () {
      const res = HttpResponseData(status: 200, contentLength: 1024);
      expect(res.toJson()['content_length'], 1024);
    });
  });

  group('HttpData', () {
    test('toJson nests request and response', () {
      const data = HttpData(
        request: HttpRequestData(
            method: 'PUT', url: 'https://s3.amazonaws.com/bucket/key'),
        response: HttpResponseData(status: 200, contentLength: 512),
      );
      final json = data.toJson();
      expect((json['request'] as Map)['method'], 'PUT');
      expect((json['response'] as Map)['status'], 200);
    });

    test('toJson omits missing request/response', () {
      const data = HttpData(response: HttpResponseData(status: 204));
      final json = data.toJson();
      expect(json.containsKey('request'), isFalse);
      expect(json.containsKey('response'), isTrue);
    });
  });
}
