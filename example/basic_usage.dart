// Example: the minimal end-to-end path — trace a unit of work in one call.
//
// tracer.trace(name, fn) creates the segment, runs fn inside the trace zone,
// closes the segment, and sends it. Use run(segment, fn) instead when you need
// to pre-build the Segment (custom parent, pre-set annotations).
//
// Prerequisite: run the X-Ray daemon locally (Docker):
//   docker run --rm -p 2000:2000/udp amazon/aws-xray-daemon:3.x -o -n us-east-1
//
// The daemon receives segments on UDP 127.0.0.1:2000 and forwards them to
// AWS X-Ray.  Segments appear in the X-Ray console ~10 s after the run.

import 'package:aws_xray_sdk/aws_xray_sdk.dart';

void main() async {
  final tracer = XRayTracer(
    serviceName: 'my-basic-service',
    sender: UdpSender(),
    sampling: FixedRateSampler(1.0),
  );

  // One call: begin segment -> run -> close -> send.
  final result = await tracer.trace('my-operation', () async {
    print('Running operation — trace: ${tracer.currentTraceId}');
    await Future.delayed(const Duration(milliseconds: 100));
    return 'done';
  });

  print('Operation completed: $result');
  print('Segment sent to X-Ray daemon');
}
