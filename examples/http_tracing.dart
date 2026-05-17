import 'dart:io';
import 'package:aws_xray_sdk/aws_xray_sdk.dart';

void main() async {
  final tracer = XRayTracer(
    serviceName: 'http-client-service',
    sender: NoopSender(),
    sampling: FixedRateSampler(1.0),
  );

  // Patch dart:io globally — every HttpClient.openUrl() call is now traced.
  XRay.patchHttp(tracer);

  final segment = Segment.begin(
    name: 'http-request',
    traceId: TraceId.generate(),
  );

  await tracer.run(segment, () async {
    print('Making HTTP request — trace: ${segment.traceId}');

    // XRayHttpClient intercepts this automatically.
    final uri = Uri.parse('https://httpbin.org/get');
    final request = await HttpClient().getUrl(uri);
    final response = await request.close();
    await response.drain<void>();

    print('Response status: ${response.statusCode}');
  });

  // Remove the global patch when done (e.g. in tests).
  XRay.unpatchHttp();

  print('Segment with HTTP subsegments sent to X-Ray daemon');
}
