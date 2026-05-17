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

    test('toJson omits optional null fields', () {
      const req = HttpRequestData(method: 'POST', url: 'https://example.com');
      final json = req.toJson();
      expect(json.containsKey('user_agent'), isFalse);
      expect(json.containsKey('client_ip'), isFalse);
      expect(json.containsKey('x_forwarded_for'), isFalse);
    });

    test('toJson includes optional fields when set', () {
      const req = HttpRequestData(
        method: 'GET',
        url: 'https://example.com',
        userAgent: 'dart/3.0',
        clientIp: '1.2.3.4',
        xForwardedFor: true,
      );
      final json = req.toJson();
      expect(json['user_agent'], 'dart/3.0');
      expect(json['client_ip'], '1.2.3.4');
      expect(json['x_forwarded_for'], isTrue);
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
