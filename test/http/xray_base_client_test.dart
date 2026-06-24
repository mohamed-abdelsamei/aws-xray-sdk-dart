import 'dart:convert';
import 'dart:io';

import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
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

    test('XRay.httpClientFor wraps an inner client and traces AWS calls',
        () async {
      final inner = _MockClient(200, responseHeaders: {
        'x-amzn-requestid': 'req-123',
      });
      final client = XRay.httpClientFor(tracer, inner: inner);

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        final req = http.Request(
          'POST',
          Uri.parse('https://dynamodb.us-east-1.amazonaws.com/'),
        )
          ..headers['X-Amz-Target'] = 'DynamoDB_20120810.GetItem'
          ..body = jsonEncode({'TableName': 'users'});
        await client.send(req);
      });

      // Same AWS-aware naming/extraction as a hand-built XRayBaseClient.
      final sub = sender.lastSubs.single as Map;
      expect(sub['name'], 'DynamoDB');
      expect(sub['namespace'], 'aws');
      final aws = sub['aws'] as Map;
      expect(aws['operation'], 'GetItem');
      expect(aws['table_name'], 'users');
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
      expect(request['traced'], isTrue);
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
      final cause = sub['cause'] as Map;
      final exc = (cause['exceptions'] as List).first as Map;
      expect(exc['type'], 'HTTP 500');
      expect(exc['message'], contains('500'));
      expect(exc['remote'], isTrue);
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

    test('aws namespace and metadata for China partition endpoints', () async {
      final inner = _MockClient(200, responseHeaders: {
        'x-amzn-requestid': 'req-cn',
      });
      final client = XRayBaseClient(inner, tracer);

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        final req = http.Request(
          'POST',
          Uri.parse('https://dynamodb.cn-north-1.amazonaws.com.cn/'),
        )
          ..headers['X-Amz-Target'] = 'DynamoDB_20120810.GetItem'
          ..body = jsonEncode({'TableName': 'users'});
        await client.send(req);
      });

      final sub = sender.lastSubs.single as Map;
      expect(sub['name'], 'DynamoDB');
      expect(sub['namespace'], 'aws');
      final aws = sub['aws'] as Map;
      expect(aws['operation'], 'GetItem');
      expect(aws['region'], 'cn-north-1');
      expect(aws['request_id'], 'req-cn');
    });

    test('aws subsegment uses the canonical service name, not the host',
        () async {
      final inner = _MockClient(200);
      final client = XRayBaseClient(inner, tracer);

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        await client.get(
          Uri.parse('https://dynamodb.us-east-1.amazonaws.com'),
        );
      });

      final sub = sender.lastSubs.first as Map;
      expect(sub['name'], 'DynamoDB');
    });

    test('attaches aws operation + table_name from JSON request', () async {
      final inner = _MockClient(200);
      final client = XRayBaseClient(inner, tracer);

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        await client.post(
          Uri.parse('https://dynamodb.us-east-1.amazonaws.com/'),
          headers: {'X-Amz-Target': 'DynamoDB_20120810.GetItem'},
          body: jsonEncode({'TableName': 'users', 'Key': <String, Object?>{}}),
        );
      });

      final sub = sender.lastSubs.first as Map;
      final aws = sub['aws'] as Map;
      expect(aws['operation'], 'GetItem');
      expect(aws['table_name'], 'users');
    });

    test('records aws request_id, region, resource_names, content_length',
        () async {
      final inner = _MockClient(
        200,
        body: '{"ok":true}',
        responseHeaders: {'x-amzn-requestid': 'REQ-123'},
      );
      final client = XRayBaseClient(inner, tracer);

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        await client.post(
          Uri.parse('https://dynamodb.us-east-1.amazonaws.com/'),
          headers: {'X-Amz-Target': 'DynamoDB_20120810.GetItem'},
          body: jsonEncode({'TableName': 'users', 'Key': <String, Object?>{}}),
        );
      });

      final sub = sender.lastSubs.first as Map;
      final aws = sub['aws'] as Map;
      expect(aws['request_id'], 'REQ-123');
      expect(aws['region'], 'us-east-1');
      expect(aws['resource_names'], ['users']);
      expect((sub['http'] as Map)['response']['content_length'], 11);
    });

    test('attaches aws operation + topic_arn from query request', () async {
      final inner = _MockClient(200);
      final client = XRayBaseClient(inner, tracer);

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        await client.post(
          Uri.parse('https://sns.us-east-1.amazonaws.com/'),
          body: 'Action=Publish&TopicArn=arn%3Aaws%3Asns%3A1%3A0%3At&Message=x',
        );
      });

      final sub = sender.lastSubs.first as Map;
      final aws = sub['aws'] as Map;
      expect(aws['operation'], 'Publish');
      expect(aws['topic_arn'], 'arn:aws:sns:1:0:t');
    });

    test('records aws error cause from JSON error body', () async {
      final inner = _MockClient(
        400,
        body: jsonEncode({
          '__type': 'com.amazonaws#ResourceNotFoundException',
          'message': 'Requested resource not found',
        }),
      );
      final client = XRayBaseClient(inner, tracer);

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        await client.post(
          Uri.parse('https://dynamodb.us-east-1.amazonaws.com/'),
          headers: {'X-Amz-Target': 'DynamoDB_20120810.GetItem'},
          body: jsonEncode({'TableName': 'missing'}),
        );
      });

      final sub = sender.lastSubs.first as Map;
      expect(sub['error'], isTrue);
      final exc = ((sub['cause'] as Map)['exceptions'] as List).first as Map;
      expect(exc['type'], 'ResourceNotFoundException');
      expect(exc['message'], 'Requested resource not found');
      expect(exc['remote'], isTrue);
      expect((sub['aws'] as Map)['table_name'], 'missing');
    });

    test('aws throttle error code marks non-429 response as throttled',
        () async {
      final inner = _MockClient(
        400,
        body: jsonEncode({
          '__type': 'com.amazonaws#ProvisionedThroughputExceededException',
          'message': 'Rate exceeded',
        }),
      );
      final client = XRayBaseClient(inner, tracer);

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        await client.post(
          Uri.parse('https://dynamodb.us-east-1.amazonaws.com/'),
          headers: {'X-Amz-Target': 'DynamoDB_20120810.GetItem'},
        );
      });

      final sub = sender.lastSubs.first as Map;
      expect(sub['throttle'], isTrue);
      expect(sub['error'], isTrue);
      final exc = ((sub['cause'] as Map)['exceptions'] as List).first as Map;
      expect(exc['type'], 'ProvisionedThroughputExceededException');
    });

    test('records aws error cause from XML error body', () async {
      final inner = _MockClient(
        403,
        body: '<ErrorResponse><Error><Code>AccessDenied</Code>'
            '<Message>User is not authorized to perform sns:Publish</Message>'
            '</Error></ErrorResponse>',
      );
      final client = XRayBaseClient(inner, tracer);

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        await client.post(
          Uri.parse('https://sns.us-east-1.amazonaws.com/'),
          body: 'Action=Publish&TopicArn=arn%3Aaws%3Asns%3A1%3A0%3At',
        );
      });

      final sub = sender.lastSubs.first as Map;
      expect(sub['error'], isTrue);
      final exc = ((sub['cause'] as Map)['exceptions'] as List).first as Map;
      expect(exc['type'], 'AccessDenied');
      expect(exc['message'], contains('sns:Publish'));
    });

    test('parses namespaced XML error tags', () async {
      final inner = _MockClient(
        400,
        body: '<ns2:ErrorResponse xmlns:ns2="http://x/"><ns2:Error>'
            '<ns2:Code>Throttling</ns2:Code>'
            '<ns2:Message>Rate exceeded</ns2:Message>'
            '</ns2:Error></ns2:ErrorResponse>',
      );
      final client = XRayBaseClient(inner, tracer);

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        await client.post(
          Uri.parse('https://sns.us-east-1.amazonaws.com/'),
          body: 'Action=Publish',
        );
      });

      final exc = ((sender.lastSubs.first as Map)['cause'] as Map)['exceptions']
          as List;
      expect((exc.first as Map)['type'], 'Throttling');
      expect((exc.first as Map)['message'], 'Rate exceeded');
    });

    test('parses XML error tags carrying attributes', () async {
      final inner = _MockClient(
        403,
        body: '<Error><Code attr="x">AccessDenied</Code>'
            '<Message xml:lang="en">Nope</Message></Error>',
      );
      final client = XRayBaseClient(inner, tracer);

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        await client.post(Uri.parse('https://sns.us-east-1.amazonaws.com/'),
            body: 'Action=Publish');
      });

      final exc = ((sender.lastSubs.first as Map)['cause'] as Map)['exceptions']
          as List;
      expect((exc.first as Map)['type'], 'AccessDenied');
      expect((exc.first as Map)['message'], 'Nope');
    });

    test('unwraps CDATA and decodes entities in XML error messages', () async {
      final inner = _MockClient(
        400,
        body: '<Error><Code>Invalid</Code>'
            '<Message><![CDATA[a < b & c]]></Message></Error>',
      );
      final client = XRayBaseClient(inner, tracer);

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        await client.post(Uri.parse('https://sns.us-east-1.amazonaws.com/'),
            body: 'Action=Publish');
      });

      final exc = ((sender.lastSubs.first as Map)['cause'] as Map)['exceptions']
          as List;
      expect((exc.first as Map)['type'], 'Invalid');
      expect((exc.first as Map)['message'], 'a < b & c');
    });

    test('out-of-range numeric XML entity does not crash the request',
        () async {
      // &#1114112; is > 0x10FFFF — String.fromCharCode would throw RangeError.
      // The error body must still flow through without faulting the call.
      final inner = _MockClient(
        400,
        body: '<Error><Code>Invalid</Code>'
            '<Message>bad &#1114112; char</Message></Error>',
      );
      final client = XRayBaseClient(inner, tracer);

      late int status;
      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        // Must not throw.
        final res = await client.post(
          Uri.parse('https://sns.us-east-1.amazonaws.com/'),
          body: 'Action=Publish',
        );
        status = res.statusCode;
      });

      expect(status, 400,
          reason: 'response is delivered, not turned into a throw');
      final exc = ((sender.lastSubs.first as Map)['cause'] as Map)['exceptions']
          as List;
      expect((exc.first as Map)['type'], 'Invalid');
      // The unconvertible entity is left literal rather than crashing.
      expect((exc.first as Map)['message'], contains('&#1114112;'));
    });

    test('falls back to header type when XML has no Code tag', () async {
      final inner = _MockClient(
        400,
        body: '<html><body>gateway error</body></html>',
        responseHeaders: {'x-amzn-errortype': 'ServiceUnavailable:'},
      );
      final client = XRayBaseClient(inner, tracer);

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        await client.post(Uri.parse('https://sns.us-east-1.amazonaws.com/'),
            body: 'Action=Publish');
      });

      final exc = ((sender.lastSubs.first as Map)['cause'] as Map)['exceptions']
          as List;
      expect((exc.first as Map)['type'], 'ServiceUnavailable');
    });

    test('aws error body is still readable by the caller', () async {
      const errBody = '{"__type":"X","message":"boom"}';
      final inner = _MockClient(400, body: errBody);
      final client = XRayBaseClient(inner, tracer);

      late String received;
      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        final res = await client.post(
          Uri.parse('https://dynamodb.us-east-1.amazonaws.com/'),
          headers: {'X-Amz-Target': 'X.Op'},
        );
        received = res.body;
      });

      expect(received, errBody);
    });

    test('un-drained response is swept as exactly one incomplete subsegment',
        () async {
      // A caller that reads only the status and never listens to the body
      // (HEAD, 204/304, status-only early return) never triggers handleDone,
      // so the deferred endSubsegment never fires. The finalize-time sweep
      // must still emit the span — once — flagged incomplete and carrying the
      // status the client knew.
      final inner = _MockClient(204);
      final client = XRayBaseClient(inner, tracer);

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        final res = await client.send(http.Request(
            'GET', Uri.parse('https://api.example.com/status-only')));
        expect(res.statusCode, 204);
        // Intentionally never drain res.stream.
      });

      expect(sender.lastSubs, hasLength(1));
      final sub = sender.lastSubs.first as Map;
      expect(((sub['metadata'] as Map)['xray'] as Map)['incomplete'], isTrue);
      expect((sub['http'] as Map)['response']['status'], 204);
      expect(sub['in_progress'], isNull); // closed by the sweep
    });

    test('drained response is exactly one subsegment, not flagged incomplete',
        () async {
      // Regression: the normal path still closes once via handleDone and is
      // never touched by the sweep (it was removed from pending on close).
      final inner = _MockClient(200);
      final client = XRayBaseClient(inner, tracer);

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        await client.get(Uri.parse('https://api.example.com/data'));
      });

      expect(sender.lastSubs, hasLength(1));
      final sub = sender.lastSubs.first as Map;
      expect(sub.containsKey('metadata'), isFalse);
    });

    test('body-stream error marks subsegment as faulted', () async {
      final inner = _ErrorStreamClient();
      final client = XRayBaseClient(inner, tracer);

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        await expectLater(
          () => client.get(Uri.parse('https://api.example.com/data')),
          throwsA(isA<Exception>()),
        );
      });

      final sub = sender.lastSubs.first as Map;
      expect(sub['fault'], isTrue);
      expect(sub['http']['request']['url'], 'https://api.example.com/data');
    });
  });

  // Reproduces the real double-tracing scenario: XRay.patchHttp() is active AND
  // an XRayBaseClient wraps a real IOClient. The IOClient's underlying dart:io
  // HttpClient is the patched XRayHttpClient, so without suppression the same
  // request would be traced twice.
  group('XRayBaseClient — no double-trace under patchHttp', () {
    late HttpServer server;
    late _RecordingSender sender;
    late XRayTracer tracer;
    late Uri serverUri;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      String? capturedTraceHeader;
      server.listen((req) async {
        capturedTraceHeader ??= req.headers.value('x-amzn-trace-id');
        req.response
          ..statusCode = 200
          ..headers.set('x-captured-trace', capturedTraceHeader ?? '')
          ..close();
      });
      serverUri = Uri.parse('http://127.0.0.1:${server.port}/data');

      sender = _RecordingSender();
      tracer = XRayTracer(
        serviceName: 'svc',
        sender: sender,
        sampling: FixedRateSampler(1.0),
      );
    });

    tearDown(() async {
      XRay.unpatchHttp();
      await server.close(force: true);
    });

    test('records exactly one subsegment, owned by XRayBaseClient', () async {
      XRay.patchHttp(tracer);

      String? sentTraceHeader;
      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        // HttpClient() here is the patched XRayHttpClient.
        final client = XRayBaseClient(IOClient(HttpClient()), tracer);
        final res = await client.get(serverUri);
        sentTraceHeader = res.headers['x-captured-trace'];
        client.close();
      });

      // Exactly one subsegment — the dart:io patch stood down.
      expect(sender.lastSubs, hasLength(1));
      final sub = sender.lastSubs.first as Map;
      expect(sub['name'], '127.0.0.1');

      // The surviving trace header points at the XRayBaseClient's subsegment,
      // proving that layer (not the patch) instrumented the request.
      expect(sentTraceHeader, contains('Parent=${sub['id']}'));
    });
  });
}

class _ErrorStreamClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream.error(Exception('connection reset')),
      200,
    );
  }
}

class _MockClient extends http.BaseClient {
  _MockClient(
    this.statusCode, {
    String body = '{}',
    Map<String, String> responseHeaders = const {},
    void Function(http.BaseRequest)? onRequest,
  })  : _body = body,
        _responseHeaders = responseHeaders,
        _onRequest = onRequest;

  final int statusCode;
  final String _body;
  final Map<String, String> _responseHeaders;
  final void Function(http.BaseRequest)? _onRequest;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _onRequest?.call(request);
    // Materialise the request body so `http.Request.body` is readable by the
    // client under test (mirrors what a real transport does).
    if (request is http.Request) {
      request.bodyBytes;
    }
    final bytes = utf8.encode(_body);
    return http.StreamedResponse(
      Stream.value(bytes),
      statusCode,
      contentLength: bytes.length,
      headers: _responseHeaders,
    );
  }
}
