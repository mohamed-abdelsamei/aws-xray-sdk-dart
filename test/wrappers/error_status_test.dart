import 'dart:convert';

import 'package:aws_xray_sdk/aws_xray_sdk.dart';
// ignore: implementation_imports
import 'package:aws_xray_sdk/src/wrappers/client_registry.dart';
// ignore: implementation_imports
import 'package:aws_xray_sdk/src/wrappers/xray_interceptor.dart';
import 'package:test/test.dart';

/// A Smithy-style exception carrying the HTTP status of the failed call.
final class _HttpError implements Exception {
  const _HttpError(this.status, [this.name = 'ValidationException']);
  final int status;
  final String name;
  @override
  String toString() => '$name: status $status';
}

SmithyRequestAdapter<Object> _req(Object _) => (
      operationName: 'GetItem',
      method: 'POST',
      url: 'https://dynamodb.us-east-1.amazonaws.com/',
      body: const {},
      withTraceHeader: (r, h) => r,
    );

SmithyResponseAdapter<Object> _res(Object _) => (
      statusCode: 200,
      contentLength: null,
      requestId: null,
      region: null,
      errorCode: null,
    );

/// An error whose `toString()` throws; [_statusHook] still maps it to 429.
final class _ThrowingToString implements Exception {
  const _ThrowingToString();
  @override
  String toString() => throw StateError('toString exploded');
}

int? _statusHook(Object e) => e is _ThrowingToString
    ? 429
    : e is _HttpError
        ? e.status
        : null;

void main() {
  late InMemorySender sender;
  late XRayTracer tracer;

  setUp(() {
    sender = InMemorySender();
    tracer = XRayTracer(
      serviceName: 'svc',
      sender: sender,
      sampling: FixedRateSampler(1.0),
    );
  });

  /// Runs one wrapped call that throws [error]; returns the subsegment JSON
  /// and asserts the original error is rethrown unchanged.
  Future<Map<String, Object?>> failWith(
    Object error, {
    int? Function(Object)? errorStatus,
  }) async {
    final send = XRayInterceptor<Object, Object>(
      tracer: tracer,
      namespace: 'aws',
      extractor: (op, _) => AwsData(operation: op),
      requestAdapter: _req,
      responseAdapter: _res,
      errorStatus: errorStatus,
    ).wrap((_) async => throw error);

    Object? caught;
    try {
      await tracer.run(tracer.beginSegment(), () => send('req'));
    } catch (e) {
      caught = e;
    }
    expect(identical(caught, error), isTrue);
    final doc = jsonDecode(jsonEncode(sender.segments.last.toJson()))
        as Map<String, Object?>;
    return (doc['subsegments'] as List).single as Map<String, Object?>;
  }

  Object? status(Map<String, Object?> sub) =>
      ((sub['http'] as Map?)?['response'] as Map?)?['status'];

  group('errorStatus hook', () {
    test('a throwing toString keeps status, throttle and cause', () async {
      final sub =
          await failWith(const _ThrowingToString(), errorStatus: _statusHook);
      expect(sub['error'], isTrue);
      expect(sub['throttle'], isTrue);
      expect(sub.containsKey('fault'), isFalse);
      expect(status(sub), 429);
      final exc = ((sub['cause'] as Map)['exceptions'] as List).single as Map;
      expect(exc['type'], '_ThrowingToString');
      expect(exc['message'], '_ThrowingToString');
    });

    test('400 records error, no fault, http.response.status', () async {
      final sub =
          await failWith(const _HttpError(400), errorStatus: _statusHook);
      expect(sub['error'], isTrue);
      expect(sub.containsKey('fault'), isFalse);
      expect(sub.containsKey('throttle'), isFalse);
      expect(status(sub), 400);
      expect(sub['cause'], isNotNull);
      expect((sub['http'] as Map)['request'], isNotNull);
    });

    test('rethrown error keeps its stack trace', () async {
      final trace = StackTrace.current;
      final send = XRayInterceptor<Object, Object>(
        tracer: tracer,
        namespace: 'aws',
        extractor: (op, _) => AwsData(operation: op),
        requestAdapter: _req,
        responseAdapter: _res,
        errorStatus: _statusHook,
      ).wrap((_) => Future.error(const _HttpError(400), trace));
      StackTrace? got;
      try {
        await tracer.run(tracer.beginSegment(), () => send('req'));
      } catch (_, st) {
        got = st;
      }
      expect(got.toString(), contains(trace.toString().split('\n').first));
    });

    test('429 records throttle and error', () async {
      final sub =
          await failWith(const _HttpError(429), errorStatus: _statusHook);
      expect(sub['throttle'], isTrue);
      expect(sub['error'], isTrue);
      expect(sub.containsKey('fault'), isFalse);
      expect(status(sub), 429);
    });

    test('503 records fault', () async {
      final sub =
          await failWith(const _HttpError(503), errorStatus: _statusHook);
      expect(sub['fault'], isTrue);
      expect(sub.containsKey('error'), isFalse);
      expect(status(sub), 503);
    });

    test('a 400 with a throttle error code is still a throttle', () async {
      final sub = await failWith(
          const _HttpError(400, 'ProvisionedThroughputExceededException'),
          errorStatus: _statusHook);
      expect(sub['throttle'], isTrue);
      expect(sub['error'], isTrue);
      expect(sub.containsKey('fault'), isFalse);
      expect(status(sub), 400);
    });

    test('no hook keeps fault', () async {
      final sub = await failWith(const _HttpError(400));
      expect(sub['fault'], isTrue);
      expect(sub.containsKey('error'), isFalse);
      expect(status(sub), isNull);
    });

    test('hook returning null keeps fault', () async {
      final sub =
          await failWith(const _HttpError(400), errorStatus: (_) => null);
      expect(sub['fault'], isTrue);
      expect(sub.containsKey('error'), isFalse);
      expect(status(sub), isNull);
    });

    test('throwing hook (Exception and Error) keeps fault', () async {
      for (final Object thrown in [StateError('boom'), Exception('boom')]) {
        sender.clear();
        final sub = await failWith(const _HttpError(400),
            errorStatus: (_) => throw thrown);
        expect(sub['fault'], isTrue);
        expect(sub.containsKey('error'), isFalse);
        expect(status(sub), isNull);
      }
    });

    test('null hook keeps throttle detection by error code', () async {
      final sub = await failWith(const _HttpError(400, 'ThrottlingException'),
          errorStatus: (_) => null);
      expect(sub['throttle'], isTrue);
      expect(sub['error'], isTrue);
      expect(sub.containsKey('fault'), isFalse);
    });

    test('a sub-400 status from the hook is ignored (fault)', () async {
      final sub =
          await failWith(const _HttpError(200), errorStatus: _statusHook);
      expect(sub['fault'], isTrue);
      expect(status(sub), isNull);
    });
  });

  group('errorStatus via XRay.registerClient / fromClient', () {
    tearDown(() => clientRegistry.remove(_Client));

    test('thrown 404 is an error, not a fault', () async {
      XRay.registerClient<_Client>(
        requestAdapter: _req,
        responseAdapter: _res,
        errorStatus: _statusHook,
        rebuild: (c, wrapSend) => _Client(wrapSend(c.send)),
      );
      expect(descriptorFor<_Client>()!.errorStatus, isNotNull);

      const err = _HttpError(404, 'ResourceNotFoundException');
      final client = XRay.fromClient(
        _Client((_) async => throw err),
        tracer: tracer,
      );

      Object? caught;
      try {
        await tracer.run(tracer.beginSegment(), () => client.send('req'));
      } catch (e) {
        caught = e;
      }
      expect(identical(caught, err), isTrue);
      final doc = jsonDecode(jsonEncode(sender.segments.last.toJson()))
          as Map<String, Object?>;
      final sub = (doc['subsegments'] as List).single as Map<String, Object?>;
      expect(sub['name'], 'GetItem');
      expect(sub['error'], isTrue);
      expect(sub.containsKey('fault'), isFalse);
      expect(status(sub), 404);
    });
  });
}

class _Client {
  _Client(this.send);
  final Future<Object> Function(Object request) send;
}
