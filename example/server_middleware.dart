// Example: server-side request tracing using handleTraced().
//
// Shows how to trace incoming HTTP requests with a single call to
// handleTraced().  It parses the incoming X-Amzn-Trace-Id header, creates a
// segment, runs the handler inside tracer.run(), and sets the response header
// with the new trace context for downstream propagation.
//
// This example uses plain dart:io HttpServer — the same pattern applies
// to any Dart web framework (shelf, angel3, etc.).
//
// Prerequisite: run the X-Ray daemon locally (Docker):
//   docker run --rm -p 2000:2000/udp amazon/aws-xray-daemon:3.x -o -n us-east-1

import 'dart:io';

import 'package:aws_xray_sdk/aws_xray_sdk.dart';

final _tracer = XRayTracer(
  serviceName: 'my-api',
  sender: UdpSender(),
  sampling: FixedRateSampler(1.0),
);

Future<void> main() async {
  // Patch outbound HTTP so downstream calls are also traced.
  XRay.patchHttp(_tracer);

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8080);
  print('Listening on http://localhost:8080');

  await for (final request in server) {
    _handleRequest(request);
  }
}

Future<void> _handleRequest(HttpRequest request) async {
  // handleTraced wraps every request in its own segment.
  // It parses X-Amzn-Trace-Id from the upstream caller, creates a segment,
  // runs the handler inside tracer.run(), and sets the response header.
  await handleTraced(request, _tracer, () => _router(request));
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
