// Example: server-side request tracing middleware pattern.
//
// Shows how to create a top-level segment for each incoming request,
// run the handler inside tracer.run(), and propagate the trace context
// from an upstream X-Amzn-Trace-Id header.
//
// This example uses plain dart:io HttpServer — the same pattern applies
// to any Dart web framework (shelf, angel3, etc.).

import 'dart:io';
import 'package:aws_xray_sdk/aws_xray_sdk.dart';

final _tracer = XRayTracer(
  serviceName: 'my-api',
  sender: NoopSender(), // swap for UdpSender() in production
  sampling: FixedRateSampler(1.0),
);

Future<void> main() async {
  // Patch outbound HTTP so downstream calls are also traced.
  XRay.patchHttp(_tracer);

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8080);
  print('Listening on http://localhost:8080');

  await for (final request in server) {
    _handleRequest(request); // fire-and-forget per request
  }
}

Future<void> _handleRequest(HttpRequest request) async {
  // Parse incoming trace context so we can continue the upstream trace.
  final upstreamHeader = request.headers.value('x-amzn-trace-id') ?? '';
  final upstreamTraceId = TraceId.tryParse(upstreamHeader);
  final parentId = TraceId.parseParentId(upstreamHeader);

  final segment = Segment.begin(
    name: 'my-api',
    traceId: upstreamTraceId ?? TraceId.generate(),
    parentId: parentId,
  );

  try {
    await _tracer.run(segment, () => _router(request));
  } catch (e) {
    request.response
      ..statusCode = HttpStatus.internalServerError
      ..write('Internal Server Error')
      ..close();
  }
}

Future<void> _router(HttpRequest request) async {
  switch (request.uri.path) {
    case '/ping':
      await _pingHandler(request);
    case '/work':
      await _workHandler(request);
    default:
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('Not Found');
      await request.response.close();
  }
}

Future<void> _pingHandler(HttpRequest request) async {
  request.response
    ..statusCode = HttpStatus.ok
    ..write('pong');
  await request.response.close();
}

Future<void> _workHandler(HttpRequest request) async {
  // Manual subsegment for a discrete unit of work inside the request.
  final sub = _tracer.beginSubsegment('compute', namespace: 'local');
  try {
    await Future.delayed(const Duration(milliseconds: 50));
    _tracer.endSubsegment(sub);
  } catch (e) {
    _tracer.failSubsegment(sub, e);
    rethrow;
  }

  request.response
    ..statusCode = HttpStatus.ok
    ..write('done');
  await request.response.close();
}
