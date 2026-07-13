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
  // (When an explicit tracer is passed, configure() installs it as-is —
  // serviceName/sampling arguments only apply when it builds the tracer.)
  XRay.configure(
    tracer: XRayTracer(
      serviceName: 'zero-config-demo',
      sender: NoopSender(), // swap for UdpSender() in production
      sampling: FixedRateSampler(1.0),
    ),
    patchDartIoHttp: false, // no real HTTP in this example
  );

  print('configured: ${XRay.isConfigured}'); // true

  // Hand XRay.aws() to any aws_client / aws_*_api constructor's `client:`
  // argument and every call is traced (bound to the global tracer):
  //
  //   final ddb = DynamoDB(region: 'us-east-1', client: XRay.aws());

  // Anywhere in the app — no tracer threading. XRay.trace() runs a complete
  // segment on the global tracer; XRay.capture() nests a span inside it.
  await XRay.trace('zero-config-op', () async {
    // Bulk annotation in one call instead of N annotate() calls.
    XRay.annotate({
      'environment': 'demo',
      'feature': 'zero-config',
      'version': 3,
    });

    await XRay.capture('inner-step', (span) async {
      span.addMetadata('detail', {'step': 1}, namespace: 'demo');
      await Future<void>.delayed(const Duration(milliseconds: 25));
    });

    print('trace: ${XRay.tracer.currentTraceId}');
  });

  // Return to the unconfigured (no-op) state — handy in tests.
  XRay.reset();
  print('configured after reset: ${XRay.isConfigured}'); // false
}
