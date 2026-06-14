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

  // Segment.begin accepts an optional namespace parameter:
  //   'aws'    — for AWS SDK calls
  //   'remote' — for external HTTP calls
  //   'local'  — for local / database work
  final segment = Segment.begin(
    name: 'my-operation',
    traceId: TraceId.generate(),
    namespace: 'local',
  ).annotate('environment', 'demo').addMetadata('request_id', '12345');

  await tracer.run(segment, () async {
    print('Running operation — trace: ${segment.traceId}');
    await Future.delayed(const Duration(milliseconds: 100));
    print('Operation completed');
  });

  // Segment is automatically closed and sent when run() completes.
  print('Segment sent to X-Ray daemon');
}
