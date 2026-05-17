import 'package:aws_xray_sdk/aws_xray_sdk.dart';

void main() async {
  final tracer = XRayTracer(
    serviceName: 'my-basic-service',
    sender: NoopSender(), // swap for UdpSender() in production
    sampling: FixedRateSampler(1.0),
  );

  final segment = Segment.begin(
    name: 'my-operation',
    traceId: TraceId.generate(),
  ).annotate('environment', 'demo').addMetadata('request_id', '12345');

  await tracer.run(segment, () async {
    print('Running operation — trace: ${segment.traceId}');
    await Future.delayed(const Duration(milliseconds: 100));
    print('Operation completed');
  });

  // Segment is automatically closed and sent when run() completes.
  print('Segment sent to X-Ray daemon');
}
