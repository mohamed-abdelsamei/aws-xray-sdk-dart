import 'package:aws_xray_sdk/aws_xray_sdk.dart';
// ignore: implementation_imports
import 'package:aws_xray_sdk/src/wrappers/xray_interceptor.dart';
import 'package:test/test.dart';

final class _AppError implements Exception {
  @override
  String toString() => 'app failure';
}

SmithyRequestAdapter<String> _okReq(String _) => (
      operationName: 'GetItem',
      method: 'POST',
      url: 'https://dynamodb.us-east-1.amazonaws.com/',
      body: const {},
      withTraceHeader: (r, h) => '$r|$h',
    );

SmithyResponseAdapter<String> _okRes(String _) => (
      statusCode: 200,
      contentLength: null,
      requestId: null,
      region: null,
      errorCode: null,
    );

void main() {
  late InMemorySender sender;
  late List<XRayDiagnostic> got;

  XRayTracer makeTracer({void Function(XRayDiagnostic)? hook}) => XRayTracer(
        serviceName: 'svc',
        sender: sender,
        sampling: FixedRateSampler(1.0),
        onDiagnostic: hook,
      );

  setUp(() {
    sender = InMemorySender();
    got = [];
  });

  Future<String> call(
    XRayTracer tracer, {
    SmithyRequestAdapter<String> Function(String)? req,
    SmithyResponseAdapter<String> Function(String)? res,
    AwsData Function(String, Map<String, Object?>)? extractor,
    int? Function(Object)? errorStatus,
    Future<String> Function(String)? inner,
  }) {
    final send = XRayInterceptor<String, String>(
      tracer: tracer,
      namespace: 'aws',
      extractor: extractor ?? (op, _) => AwsData(operation: op),
      requestAdapter: req ?? _okReq,
      responseAdapter: res ?? _okRes,
      errorStatus: errorStatus,
    ).wrap(inner ?? (r) async => 'ok:$r');
    return tracer.run(tracer.beginSegment(), () => send('req'));
  }

  void expectOne(String site, Object thrown) {
    expect(got, hasLength(1));
    expect(got.single.code, 'adapter_failed');
    expect(got.single.message, contains(site));
    expect(got.single.error, same(thrown));
    expect(got.single.stackTrace, isNotNull);
  }

  test('requestAdapter failure is reported; the call is sent untraced',
      () async {
    final boom = StateError('req');
    final r = await call(makeTracer(hook: got.add), req: (_) => throw boom);
    expect(r, 'ok:req'); // untraced: no trace header appended
    expectOne('requestAdapter', boom);
    expect(sender.segments.single.subsegments, isEmpty);
  });

  test('withTraceHeader failure is reported; the call is still sent', () async {
    final boom = StateError('hdr');
    final r = await call(makeTracer(hook: got.add),
        req: (_) => (
              operationName: 'GetItem',
              method: 'POST',
              url: 'https://x.example/',
              body: const {},
              withTraceHeader: (r, h) => throw boom,
            ));
    expect(r, 'ok:req'); // the original request was sent
    expectOne('withTraceHeader', boom);
    expect(sender.segments.single.subsegments, hasLength(1));
  });

  test('resource extractor failure is reported', () async {
    final boom = StateError('ext');
    final r =
        await call(makeTracer(hook: got.add), extractor: (op, b) => throw boom);
    expect(r, startsWith('ok:req'));
    expectOne('extractor', boom);
  });

  test('responseAdapter failure is reported; the response is returned',
      () async {
    final boom = StateError('res');
    final r = await call(makeTracer(hook: got.add), res: (_) => throw boom);
    expect(r, startsWith('ok:req'));
    expectOne('recording the response failed', boom);
  });

  test('errorStatus failure is reported; the original error is rethrown',
      () async {
    final boom = StateError('status');
    final appError = _AppError();
    Object? caught;
    try {
      await call(makeTracer(hook: got.add),
          errorStatus: (_) => throw boom, inner: (_) async => throw appError);
    } catch (e) {
      caught = e;
    }
    expect(caught, same(appError));
    expectOne('errorStatus', boom);
  });

  test('the inner send\'s own failure is not reported', () async {
    final appError = _AppError();
    Object? caught;
    try {
      await call(makeTracer(hook: got.add),
          errorStatus: (_) => 500, inner: (_) async => throw appError);
    } catch (e) {
      caught = e;
    }
    expect(caught, same(appError));
    expect(got, isEmpty);
  });

  test('a throwing hook never reaches the app', () async {
    final tracer = makeTracer(hook: (_) => throw StateError('hook'));
    final r = await call(tracer, res: (_) => throw StateError('res'));
    expect(r, startsWith('ok:req'));
  });

  test('no hook: behaviour is unchanged', () async {
    final tracer = makeTracer();
    expect(await call(tracer, req: (_) => throw StateError('x')), 'ok:req');
    expect(await call(tracer, res: (_) => throw StateError('x')),
        startsWith('ok:req'));
    expect(sender.segments, hasLength(2));
  });
}
