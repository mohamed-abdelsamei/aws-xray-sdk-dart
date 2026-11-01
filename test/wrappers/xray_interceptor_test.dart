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
  const _Res(
    this.statusCode, {
    this.requestId,
    this.region,
    this.errorCode,
  });
  final int statusCode;
  final String? requestId;
  final String? region;
  final String? errorCode;
}

final class ProvisionedThroughputExceededException implements Exception {
  @override
  String toString() => 'ProvisionedThroughputExceededException: Rate exceeded';
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
        requestId: res.requestId,
        region: res.region,
        errorCode: res.errorCode,
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

    test('AC3.1: recorded url has no userinfo, query, or fragment', () async {
      final send = _makeInterceptor(tracer).wrap((_) async => const _Res(200));

      final segment = tracer.beginSegment();
      await tracer.run(
        segment,
        () => send(_Req(
          url: 'https://user:pw@h.example/p?X-Amz-Signature=abc#f',
        )),
      );

      final http = sender.firstSub['http'] as Map;
      expect(http['request']['url'], 'https://h.example/p');
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
      expect((http['request'] as Map)['traced'], isTrue);
    });

    test('records aws request_id and adapter-provided region', () async {
      final interceptor = _makeInterceptor(tracer);
      final send = interceptor.wrap((_) async => const _Res(
            200,
            requestId: 'REQ-1',
            region: 'eu-west-1',
          ));

      final segment = tracer.beginSegment();
      await tracer.run(segment,
          () => send(_Req(url: 'https://dynamodb.us-east-1.amazonaws.com')));

      final aws = sender.firstSub['aws'] as Map;
      expect(aws['request_id'], 'REQ-1');
      expect(aws['region'], 'eu-west-1');
    });

    test('derives aws region from request url when adapter omits it', () async {
      final interceptor = _makeInterceptor(tracer);
      final send = interceptor.wrap((_) async => const _Res(200));

      final segment = tracer.beginSegment();
      await tracer.run(segment,
          () => send(_Req(url: 'https://sqs.ap-southeast-2.amazonaws.com')));

      final aws = sender.firstSub['aws'] as Map;
      expect(aws['region'], 'ap-southeast-2');
    });

    test('sets fault=true on 5xx response', () async {
      final interceptor = _makeInterceptor(tracer);
      final send = interceptor.wrap((_) async => const _Res(500));

      final segment = tracer.beginSegment();
      await tracer.run(segment, () => send(_Req(url: 'https://example.com')));

      expect(sender.firstSub['fault'], isTrue);
      final cause = sender.firstSub['cause'] as Map;
      final exception = (cause['exceptions'] as List).first as Map;
      expect(exception['type'], 'HTTP 500');
      expect(exception['message'], contains('500'));
      expect(exception['remote'], isTrue);
    });

    test('sets throttle=true for AWS throttle error code on non-429 response',
        () async {
      final interceptor = _makeInterceptor(tracer);
      final send = interceptor.wrap((_) async => const _Res(
            400,
            errorCode: 'ProvisionedThroughputExceededException',
          ));

      final segment = tracer.beginSegment();
      await tracer.run(segment, () => send(_Req(url: 'https://example.com')));

      expect(sender.firstSub['throttle'], isTrue);
      expect(sender.firstSub['error'], isTrue);
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
      final http = sender.firstSub['http'] as Map;
      expect((http['request'] as Map)['traced'], isTrue);
    });

    test('records thrown AWS throttle exception as throttle', () async {
      final interceptor = _makeInterceptor(tracer);
      final send = interceptor
          .wrap((_) async => throw ProvisionedThroughputExceededException());

      final segment = tracer.beginSegment();
      await expectLater(
        () => tracer.run(segment, () => send(_Req(url: 'https://example.com'))),
        throwsA(isA<ProvisionedThroughputExceededException>()),
      );

      expect(sender.firstSub['throttle'], isTrue);
      expect(sender.firstSub['error'], isTrue);
      expect(sender.firstSub['fault'], isNull);
      final exceptions =
          (sender.firstSub['cause'] as Map)['exceptions'] as List;
      expect(
          exceptions.first['type'], 'ProvisionedThroughputExceededException');
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

  group('XRayInterceptor containment', () {
    late InMemorySender mem;
    late XRayTracer memTracer;

    setUp(() {
      mem = InMemorySender();
      memTracer = XRayTracer(
        serviceName: 'svc',
        sender: mem,
        sampling: FixedRateSampler(1.0),
      );
    });

    XRayInterceptor<_Req, _Res> make({
      bool requestThrows = false,
      bool headerThrows = false,
      bool responseThrows = false,
    }) =>
        XRayInterceptor(
          tracer: memTracer,
          namespace: 'remote',
          extractor: (op, body) => AwsData(operation: op),
          requestAdapter: (req) {
            if (requestThrows) throw StateError('request adapter');
            return (
              operationName: 'TestOp',
              method: 'GET',
              url: req.url,
              body: const {},
              withTraceHeader: (r, h) =>
                  headerThrows ? throw StateError('header') : r.withHeader(h),
            );
          },
          responseAdapter: (res) {
            if (responseThrows) throw StateError('response adapter');
            return (
              statusCode: res.statusCode,
              contentLength: null,
              requestId: null,
              region: null,
              errorCode: null,
            );
          },
        );

    Future<T> traced<T>(Future<T> Function() fn) =>
        memTracer.run(memTracer.beginSegment(), fn);

    List<Map<String, Object?>> subs() {
      final json = jsonDecode(jsonEncode(mem.segments.single.toJson()))
          as Map<String, Object?>;
      return [
        for (final s in json['subsegments'] as List? ?? const [])
          s as Map<String, Object?>,
      ];
    }

    void expectClosedNotSwept(Map<String, Object?> sub) {
      expect(sub.containsKey('in_progress'), isFalse);
      expect(sub.containsKey('end_time'), isTrue);
      final xray = (sub['metadata'] as Map?)?['xray'] as Map?;
      expect(xray?['incomplete'], isNull);
    }

    test('AC1.1 request adapter throws: inner runs once untraced', () async {
      final original = _Req(url: 'https://example.com');
      const result = _Res(200);
      final calls = <_Req>[];
      final send = make(requestThrows: true).wrap((req) async {
        calls.add(req);
        return result;
      });

      final got = await traced(() => send(original));

      expect(identical(got, result), isTrue);
      expect(calls, hasLength(1));
      expect(identical(calls.single, original), isTrue);
      expect(subs(), isEmpty);
    });

    test('AC1.2 withTraceHeader throws: original request sent, still traced',
        () async {
      final original = _Req(url: 'https://example.com');
      const result = _Res(200);
      final calls = <_Req>[];
      final send = make(headerThrows: true).wrap((req) async {
        calls.add(req);
        return result;
      });

      final got = await traced(() => send(original));

      expect(identical(got, result), isTrue);
      expect(calls, hasLength(1));
      expect(identical(calls.single, original), isTrue);
      final recorded = subs();
      expect(recorded, hasLength(1));
      expect(recorded.single['name'], 'TestOp');
      expectClosedNotSwept(recorded.single);
    });

    test('AC1.3 response adapter throws: response returned, closed sub',
        () async {
      const result = _Res(200);
      final send = make(responseThrows: true).wrap((_) async => result);

      final got = await traced(() => send(_Req(url: 'https://example.com')));

      expect(identical(got, result), isTrue);
      final recorded = subs();
      expect(recorded, hasLength(1));
      final sub = recorded.single;
      expectClosedNotSwept(sub);
      expect(sub['fault'], isNull);
      expect(sub['error'], isNull);
      final http = sub['http'] as Map?;
      expect(http?['response'], isNull);
    });

    test('AC1.4 inner error is rethrown identically with its stack trace',
        () async {
      final error = StateError('boom');
      final stack = StackTrace.fromString('marker-frame');
      final send =
          make().wrap((_) async => Error.throwWithStackTrace(error, stack));

      Object? caught;
      StackTrace? caughtStack;
      try {
        await traced(() => send(_Req(url: 'https://example.com')));
      } catch (e, st) {
        caught = e;
        caughtStack = st;
      }

      expect(identical(caught, error), isTrue);
      expect(caughtStack.toString(), contains('marker-frame'));
      final sub = subs().single;
      expectClosedNotSwept(sub);
      expect(sub['fault'], isTrue);
    });

    test('AC1.4 inner error is rethrown even when failure enrichment throws',
        () async {
      final error = _ToStringThrows();
      final send = make().wrap((_) async => throw error);

      // Caught inside the trace so the root segment does not record it too
      // (root-level toString guarding is T11's scope).
      Object? caught;
      await traced(() async {
        try {
          await send(_Req(url: 'https://example.com'));
        } catch (e) {
          caught = e;
        }
      });

      expect(identical(caught, error), isTrue);
      final sub = subs().single;
      expectClosedNotSwept(sub);
      expect(sub['fault'], isTrue);
    });
  });
}

final class _ToStringThrows implements Exception {
  @override
  String toString() => throw StateError('toString');
}
