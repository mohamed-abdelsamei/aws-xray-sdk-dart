import 'dart:convert';

import 'package:aws_xray_sdk/aws_xray_sdk.dart';
// ignore: implementation_imports
import 'package:aws_xray_sdk/src/wrappers/xray_interceptor.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Minimal request/response stubs
// ---------------------------------------------------------------------------
class _Req {
  _Req({required this.url, this.traceHeader});
  final String url;
  final String? traceHeader;
  _Req withHeader(String value) => _Req(url: url, traceHeader: value);
}

class _Res {
  const _Res(this.statusCode);
  final int statusCode;
}
// ---------------------------------------------------------------------------

/// Records every segment sent to it for assertion.
class _RecordingSender extends Sender {
  final List<Map<String, Object?>> sent = [];

  @override
  Future<void> send(Segment segment) async {
    sent.add(jsonDecode(jsonEncode(segment.toJson())) as Map<String, Object?>);
  }

  @override
  Future<void> close() async {}

  Map<String, Object?> get lastSegment => sent.last;

  List get subsegments => lastSegment['subsegments'] as List? ?? const [];

  Map<String, Object?> get firstSub =>
      subsegments.first as Map<String, Object?>;
}

XRayInterceptor<_Req, _Res> _makeInterceptor(XRayTracer tracer) =>
    XRayInterceptor(
      tracer: tracer,
      namespace: 'remote',
      extractor: (op, body) => AwsData(operation: op),
      requestAdapter: (req) => (
        operationName: 'TestOp',
        method: 'GET',
        url: req.url,
        body: const {},
        withTraceHeader: (r, h) => r.withHeader(h),
      ),
      responseAdapter: (res) => (
        statusCode: res.statusCode,
        contentLength: null,
      ),
    );

void main() {
  late _RecordingSender sender;
  late XRayTracer tracer;

  setUp(() {
    sender = _RecordingSender();
    tracer = XRayTracer(
      serviceName: 'svc',
      sender: sender,
      sampling: FixedRateSampler(1.0),
    );
  });

  group('XRayInterceptor', () {
    test('passes through when no active segment', () async {
      final interceptor = _makeInterceptor(tracer);
      var innerCalled = false;

      final send = interceptor.wrap((req) async {
        innerCalled = true;
        return const _Res(200);
      });

      await send(_Req(url: 'https://example.com'));
      expect(innerCalled, isTrue);
      expect(sender.sent, isEmpty); // nothing sent — no active segment
    });

    test('injects X-Amzn-Trace-Id header on the request', () async {
      final interceptor = _makeInterceptor(tracer);
      String? receivedHeader;

      final send = interceptor.wrap((req) async {
        receivedHeader = req.traceHeader;
        return const _Res(200);
      });

      final segment = tracer.beginSegment();
      await tracer.run(segment, () => send(_Req(url: 'https://example.com')));

      expect(receivedHeader, contains('Root='));
      expect(receivedHeader, contains('Parent='));
      expect(receivedHeader, contains('Sampled=1'));
    });

    test('creates a subsegment with the operation name', () async {
      final interceptor = _makeInterceptor(tracer);
      final send = interceptor.wrap((_) async => const _Res(200));

      final segment = tracer.beginSegment();
      await tracer.run(segment, () => send(_Req(url: 'https://example.com')));

      expect(sender.subsegments, hasLength(1));
      expect(sender.firstSub['name'], 'TestOp');
      expect(sender.firstSub['namespace'], 'remote');
    });

    test('records http response data on the subsegment', () async {
      final interceptor = _makeInterceptor(tracer);
      final send = interceptor.wrap((_) async => const _Res(201));

      final segment = tracer.beginSegment();
      await tracer.run(
          segment, () => send(_Req(url: 'https://api.example.com')));

      final http = sender.firstSub['http'] as Map;
      expect((http['response'] as Map)['status'], 201);
    });

    test('sets fault=true on 5xx response', () async {
      final interceptor = _makeInterceptor(tracer);
      final send = interceptor.wrap((_) async => const _Res(500));

      final segment = tracer.beginSegment();
      await tracer.run(segment, () => send(_Req(url: 'https://example.com')));

      expect(sender.firstSub['fault'], isTrue);
    });

    test('sets throttle=true on 429 response', () async {
      final interceptor = _makeInterceptor(tracer);
      final send = interceptor.wrap((_) async => const _Res(429));

      final segment = tracer.beginSegment();
      await tracer.run(segment, () => send(_Req(url: 'https://example.com')));

      expect(sender.firstSub['throttle'], isTrue);
      expect(sender.firstSub['error'], isTrue);
    });

    test('sets error=true on 4xx response', () async {
      final interceptor = _makeInterceptor(tracer);
      final send = interceptor.wrap((_) async => const _Res(400));

      final segment = tracer.beginSegment();
      await tracer.run(segment, () => send(_Req(url: 'https://example.com')));

      expect(sender.firstSub['error'], isTrue);
      expect(sender.firstSub['fault'], isNull);
    });

    test('records fault and cause on thrown exception', () async {
      final interceptor = _makeInterceptor(tracer);
      final send = interceptor.wrap((_) async => throw Exception('timeout'));

      final segment = tracer.beginSegment();
      await expectLater(
        () => tracer.run(segment, () => send(_Req(url: 'https://example.com'))),
        throwsException,
      );

      expect(sender.firstSub['fault'], isTrue);
      final cause = sender.firstSub['cause'] as Map;
      final exceptions = cause['exceptions'] as List;
      expect(exceptions.first['message'], contains('timeout'));
    });

    test('subsegment is closed (no in_progress) after the call', () async {
      final interceptor = _makeInterceptor(tracer);
      final send = interceptor.wrap((_) async => const _Res(200));

      final segment = tracer.beginSegment();
      await tracer.run(segment, () => send(_Req(url: 'https://example.com')));

      expect(sender.firstSub.containsKey('in_progress'), isFalse);
      expect(sender.firstSub.containsKey('end_time'), isTrue);
    });
  });
}
