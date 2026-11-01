// Subprocess fixture for the daemon-address warning tests: calls
// XRay.configure in the mode given as the first argument, then prints "done"
// on stdout. Reads AWS_XRAY_DAEMON_ADDRESS from the environment.
import 'dart:async';
import 'dart:io';

import 'package:aws_xray_sdk/aws_xray_sdk.dart';

Future<void> main(List<String> args) async {
  final mode = args.isEmpty ? 'plain' : args.first;
  switch (mode) {
    case 'hook':
      XRay.configure(
        patchDartIoHttp: false,
        onDiagnostic: (d) => stdout.writeln('hook ${d.code}'),
      );
    case 'tracer':
      XRay.configure(
        patchDartIoHttp: false,
        tracer: XRayTracer(serviceName: 'svc', sender: NoopSender()),
      );
    default:
      XRay.configure(patchDartIoHttp: false);
  }
  // Give any asynchronous stderr failure time to surface.
  await Future<void>.delayed(const Duration(milliseconds: 200));
  stdout.writeln('done');
}
