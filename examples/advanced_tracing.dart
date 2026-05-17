import 'package:aws_xray_sdk/aws_xray_sdk.dart';

void main() async {
  final tracer = XRayTracer(
    serviceName: 'advanced-tracing-service',
    sender: NoopSender(),
    sampling: FixedRateSampler(1.0),
  );

  final segment = Segment.begin(
    name: 'user-request',
    traceId: TraceId.generate(),
  ).annotate('user_id', 'user-12345');

  await tracer.run(segment, () async {
    print('Starting advanced tracing — trace: ${segment.traceId}');

    // Database subsegment.
    final dbSub = tracer.beginSubsegment('database-query', namespace: 'local');
    try {
      await Future.delayed(const Duration(milliseconds: 50));

      final userSub = tracer.beginSubsegment('user-query', namespace: 'local');
      try {
        await Future.delayed(const Duration(milliseconds: 25));
        print('User query completed');
      } finally {
        tracer.endSubsegment(userSub);
      }

      print('Database query completed');
    } finally {
      tracer.endSubsegment(dbSub);
    }

    // External API subsegment.
    final apiSub =
        tracer.beginSubsegment('external-api-call', namespace: 'remote');
    try {
      await Future.delayed(const Duration(milliseconds: 200));
      print('External API call completed');
      tracer.endSubsegment(apiSub);
    } catch (e) {
      tracer.failSubsegment(apiSub, e);
      rethrow;
    }

    // File processing subsegment using begin/end directly.
    final fileSub =
        tracer.beginSubsegment('file-processing', namespace: 'local');
    try {
      await Future.delayed(const Duration(milliseconds: 100));
      print('File processing completed');
      tracer.endSubsegment(fileSub);
    } catch (e) {
      tracer.failSubsegment(fileSub, e);
      rethrow;
    }

    print('All operations completed');
  });

  print('Advanced tracing completed — all subsegments sent');
}
