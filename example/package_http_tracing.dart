// Example: tracing outbound HTTP via XRayBaseClient (package:http).
//
// Shows how to trace every request made through package:http's Client class.
// XRayBaseClient wraps any http.Client, opens a subsegment per request,
// injects X-Amzn-Trace-Id, and records the response status.
//
// Use this instead of XRay.patchHttp() when:
//   - Your HTTP calls go through package:http rather than dart:io HttpClient.
//   - You already pass an http.Client to your dependencies (DI pattern).
//
// Prerequisite: run the X-Ray daemon locally (Docker):
//   docker run --rm -p 2000:2000/udp amazon/aws-xray-daemon:3.x -o -n us-east-1

import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:http/http.dart' as http;

Future<void> main() async {
  final tracer = XRayTracer(
    serviceName: 'package-http-demo',
    sender: UdpSender(),
    sampling: FixedRateSampler(1.0),
  );

  // Wrap any http.Client with XRayBaseClient.
  // All requests through this client open subsegments automatically.
  final client = XRayBaseClient(http.Client(), tracer);

  final segment = Segment.begin(
    name: 'package-http-demo',
    traceId: TraceId.generate(),
    namespace: 'local',
  );

  await tracer.run(segment, () async {
    print('Trace: ${segment.traceId}');

    // Each send() call opens a subsegment named by the host,
    // injects X-Amzn-Trace-Id, and records the response.
    final response = await client.get(
      Uri.parse('https://jsonplaceholder.typicode.com/users/1'),
    );
    print('GET /users/1 → ${response.statusCode}');

    // 4xx responses mark the subsegment as error.
    final notFound = await client.get(
      Uri.parse('https://jsonplaceholder.typicode.com/users/999'),
    );
    print('GET /users/999 → ${notFound.statusCode}');

    // AWS endpoints automatically get namespace='aws'.
    final awsResp = await client.get(
      Uri.parse('https://dynamodb.us-east-1.amazonaws.com'),
    );
    print('GET dynamodb → ${awsResp.statusCode}');
  });

  // http.Client implementations should be closed when done.
  client.close();
  print('Segment with HTTP subsegments sent to X-Ray daemon');
}
