// Example: zero-config setup with XRay.configure().
//
// The fastest way to wire up tracing. XRay.configure():
//   - reads AWS_XRAY_DAEMON_ADDRESS (IPv6-safe) and AWS_LAMBDA_FUNCTION_NAME,
//   - builds a tracer and installs it as the process-wide default (XRay.tracer),
//   - patches dart:io HTTP,
// all in one idempotent call. Until it runs, XRay.tracer is a no-op that
// discards everything, so instrumentation is always safe to call.
//
// This example passes an explicit tracer (NoopSender + always-on sampling) so
// it runs deterministically without a daemon. In a real service you would call
// simply `XRay.configure();` and let it read the environment.

import 'package:aws_xray_sdk/aws_xray_sdk.dart';

Future<void> main() async {
  // One-call setup. In production this is just `XRay.configure();`.
  XRay.configure(
    serviceName: 'zero-config-demo',
    tracer: XRayTracer(
      serviceName: 'zero-config-demo',
      sender: NoopSender(), // swap for UdpSender() in production
      sampling: FixedRateSampler(1.0),
    ),
    patchDartIoHttp: false, // no real HTTP in this example
  );

  print('configured: ${XRay.isConfigured}'); // true

  // Anywhere in the app — no tracer threading. XRay.tracer is the global one.
  final tracer = XRay.tracer;

  // Hand XRay.aws() to any aws_client / aws_*_api constructor's `client:`
  // argument and every call is traced (bound to the global tracer):
  //
  //   final ddb = DynamoDB(region: 'us-east-1', client: XRay.aws());

  await tracer.run(tracer.beginSegment(), () async {
    // Bulk annotation in one call instead of N annotate() calls.
    tracer.annotateAll({
      'environment': 'demo',
      'feature': 'zero-config',
      'version': 3,
    });

    print('trace: ${tracer.currentTraceId}');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  // Return to the unconfigured (no-op) state — handy in tests.
  XRay.reset();
  print('configured after reset: ${XRay.isConfigured}'); // false
}
