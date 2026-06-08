import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('HttpRequestData', () {
    test('toJson includes required fields', () {
      const req = HttpRequestData(method: 'GET', url: 'https://example.com');
      final json = req.toJson();
      expect(json['method'], 'GET');
      expect(json['url'], 'https://example.com');
    });

    test('toJson contains only method and url', () {
      const req = HttpRequestData(method: 'POST', url: 'https://example.com');
      expect(req.toJson().keys, unorderedEquals(['method', 'url']));
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
