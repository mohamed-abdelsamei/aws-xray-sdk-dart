import 'dart:convert';

import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';


class _RecordingSender extends Sender {
  final List<Map<String, Object?>> sent = [];

  @override
  Future<void> send(Segment segment) async {
    sent.add(jsonDecode(jsonEncode(segment.toJson())) as Map<String, Object?>);
  }

  @override
  Future<void> close() async {}

  bool get isEmpty => sent.isEmpty;
  Map<String, Object?> get last => sent.last;
  List get lastSubs => last['subsegments'] as List? ?? const [];
}

void main() {
  group('XRayBaseClient', () {
    late _RecordingSender sender;
    late XRayTracer tracer;

    setUp(() {
      sender = _RecordingSender();
      tracer = XRayTracer(
        serviceName: 'test-svc',
        sender: sender,
        sampling: FixedRateSampler(1.0),
      );
    });

    test('passes through when no active segment', () async {
      final inner = _MockClient(200);
      final client = XRayBaseClient(inner, tracer);
      final res = await client.get(Uri.parse('https://example.com'));
      expect(res.statusCode, 200);
      expect(sender.isEmpty, isTrue);
    });

    test('creates a subsegment for each request', () async {
      final inner = _MockClient(200);
      final client = XRayBaseClient(inner, tracer);

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        await client.get(Uri.parse('https://api.example.com/data'));
      });

      expect(sender.lastSubs, hasLength(1));
      final sub = sender.lastSubs.first as Map;
      expect(sub['name'], 'api.example.com');
      expect(sub['namespace'], 'remote');
    });

    test('injects X-Amzn-Trace-Id header', () async {
      String? capturedHeader;
      final inner = _MockClient(200, onRequest: (req) {
        capturedHeader = req.headers['x-amzn-trace-id'];
      });
      final client = XRayBaseClient(inner, tracer);

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        await client.get(Uri.parse('https://api.example.com'));
      });

      expect(capturedHeader, contains('Root='));
      expect(capturedHeader, contains('Parent='));
      expect(capturedHeader, contains('Sampled=1'));
    });

    test('records HTTP method and URL on subsegment', () async {
      final inner = _MockClient(200);
      final client = XRayBaseClient(inner, tracer);

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        await client.post(
          Uri.parse('https://api.example.com/submit'),
          body: 'payload',
        );
      });

      final sub = sender.lastSubs.first as Map;
      final http = sub['http'] as Map;
      final request = http['request'] as Map;
      expect(request['method'], 'POST');
      expect(request['url'], 'https://api.example.com/submit');
    });

    test('records response status code', () async {
      final inner = _MockClient(404);
      final client = XRayBaseClient(inner, tracer);

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        await client.get(Uri.parse('https://api.example.com/not-found'));
      });

      final sub = sender.lastSubs.first as Map;
      final http = sub['http'] as Map;
      final response = http['response'] as Map;
      expect(response['status'], 404);
    });

    test('5xx marks subsegment as fault', () async {
      final inner = _MockClient(500);
      final client = XRayBaseClient(inner, tracer);

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        await client.get(Uri.parse('https://api.example.com/error'));
      });

      final sub = sender.lastSubs.first as Map;
      expect(sub['fault'], isTrue);
    });

    test('429 marks subsegment as throttle', () async {
      final inner = _MockClient(429);
      final client = XRayBaseClient(inner, tracer);

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        await client.get(Uri.parse('https://api.example.com/rate-limited'));
      });

      final sub = sender.lastSubs.first as Map;
      expect(sub['throttle'], isTrue);
      expect(sub['error'], isTrue);
    });

    test('aws namespace for *.amazonaws.com hosts', () async {
      final inner = _MockClient(200);
      final client = XRayBaseClient(inner, tracer);

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        await client.get(
          Uri.parse('https://dynamodb.us-east-1.amazonaws.com'),
        );
      });

      final sub = sender.lastSubs.first as Map;
      expect(sub['namespace'], 'aws');
    });
  });
}

class _MockClient extends http.BaseClient {
  _MockClient(this.statusCode, {void Function(http.BaseRequest)? onRequest})
      : _onRequest = onRequest;

  final int statusCode;
  final void Function(http.BaseRequest)? _onRequest;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _onRequest?.call(request);
    return http.StreamedResponse(
      Stream.value(utf8.encode('{}')),
      statusCode,
    );
  }
}
