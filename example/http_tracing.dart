// Example: automatic HTTP tracing via XRay.patchHttp().
//
// After a single patchHttp() call every HttpClient opened in the process
// (including inside third-party packages that use package:http's IOClient)
// is wrapped by XRayHttpClient, which:
//   - opens a subsegment named by the request host
//   - injects X-Amzn-Trace-Id into the outbound request
//   - records HTTP method, URL, and response status
//   - marks the subsegment as fault/error when the request fails
//
// namespace is 'remote' for general hosts, 'aws' for *.amazonaws.com hosts.
//
// Prerequisite: run the X-Ray daemon locally (Docker):
//   docker run --rm -p 2000:2000/udp amazon/aws-xray-daemon:3.x -o -n us-east-1

import 'dart:io';

import 'package:aws_xray_sdk/aws_xray_sdk.dart';

void main() async {
  final tracer = XRayTracer(
    serviceName: 'http-demo',
    sender: UdpSender(),
    sampling: FixedRateSampler(1.0),
  );

  // Patch dart:io ONCE at startup.
  // Call this before creating any HttpClient — patching affects all clients
  // constructed after this point.  Do not call twice; double-patching wraps
  // XRayHttpClient inside itself and produces duplicate subsegments.
  XRay.patchHttp(tracer);

  final segment = Segment.begin(
    name: 'http-demo',
    traceId: TraceId.generate(),
  );

  await tracer.run(segment, () async {
    print('Trace: ${segment.traceId}');

    // ── Request 1: successful GET ─────────────────────────────────────────
    // XRayHttpClient intercepts getUrl, opens subsegment 'jsonplaceholder.typicode.com'
    // (namespace='remote'), then closes it with status=200 on response.
    final client = HttpClient();
    try {
      final req = await client.getUrl(
        Uri.parse('https://jsonplaceholder.typicode.com/users/1'),
      );
      final res = await req.close();
      await res.drain<void>();
      print('GET /users/1 → ${res.statusCode}');
    } finally {
      client.close();
    }

    // ── Request 2: 404 ────────────────────────────────────────────────────
    // The subsegment is marked error=true (4xx) automatically.
    final client2 = HttpClient();
    try {
      final req = await client2.getUrl(
        Uri.parse('https://jsonplaceholder.typicode.com/users/999'),
      );
      final res = await req.close();
      await res.drain<void>();
      print('GET /users/999 → ${res.statusCode}');
    } finally {
      client2.close();
    }
  });

  // Restore previous overrides (important in tests to avoid cross-test leakage).
  XRay.unpatchHttp();

  print('Done — segment contains HTTP subsegments for both requests');
}
