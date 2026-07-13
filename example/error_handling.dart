// Example: how errors, faults, and throttles are recorded on segments.
//
//   4xx  → error = true          (withError)
//   429  → throttle = true       (withThrottle; error is implied)
//   5xx  → fault = true          (withFault)
//   uncaught exception in run()  → fault = true + 'cause' with the exception
//
// Also shows that a failed subsegment (failSubsegment) records its own error
// without failing the parent segment — later subsegments still run.

import 'package:aws_xray_sdk/aws_xray_sdk.dart';

void main() async {
  print('=== Error Handling and Fault Detection Examples ===\n');

  final tracer = XRayTracer(
    serviceName: 'error-handling-service',
    sender: NoopSender(),
    sampling: FixedRateSampler(1.0),
  );

  // Successful operation.
  await _runOperation(tracer, 'successful-operation');

  // Client error (4xx) — mark segment as error.
  await _runOperation(tracer, 'client-error-operation', httpStatus: 400);

  // Server fault (5xx) — mark segment as fault.
  await _runOperation(tracer, 'server-fault-operation', httpStatus: 500);

  // Throttled request (429).
  await _runOperation(tracer, 'throttled-operation', httpStatus: 429);

  // Unexpected exception.
  await _runOperation(
    tracer,
    'network-error-operation',
    exception: Exception('Connection timeout'),
  );

  // Nested subsegments with mixed outcomes.
  await _runNestedErrors(tracer);
}

Future<void> _runOperation(
  XRayTracer tracer,
  String name, {
  int? httpStatus,
  Exception? exception,
}) async {
  // Pre-building the segment (to apply error flags before running) is the
  // use case run() exists for; for the plain path prefer tracer.trace().
  var segment = Segment.begin(
    name: name,
    traceId: TraceId.generate(),
  );

  if (httpStatus != null) {
    // Pre-apply status flags so they are captured in the final segment.
    if (httpStatus == 429) {
      segment = segment.withThrottle();
    } else if (httpStatus >= 500) {
      segment = segment.withFault();
    } else if (httpStatus >= 400) {
      segment = segment.withError();
    }
  }

  try {
    await tracer.run(segment, () async {
      print('Running $name');
      await Future.delayed(const Duration(milliseconds: 50));
      if (exception != null) throw exception;
      print('$name completed');
    });
  } catch (e) {
    print('$name raised: $e');
  }
}

Future<void> _runNestedErrors(XRayTracer tracer) async {
  try {
    await tracer.trace('parent-with-nested-errors', () async {
      print('Running parent operation');

      // Successful subsegment.
      final ok = tracer.beginSubsegment('successful-subtask');
      await Future.delayed(const Duration(milliseconds: 50));
      tracer.endSubsegment(ok);
      print('Successful subtask done');

      // Failing subsegment — error is recorded in the subsegment.
      final bad = tracer.beginSubsegment('failing-subtask');
      try {
        await Future.delayed(const Duration(milliseconds: 50));
        throw Exception('Invalid input');
      } catch (e) {
        tracer.failSubsegment(bad, e);
        print('Failing subtask error caught: $e');
      }

      // Third subsegment — still runs after the failure above.
      final ok2 = tracer.beginSubsegment('recovery-subtask');
      await Future.delayed(const Duration(milliseconds: 30));
      tracer.endSubsegment(ok2);
      print('Recovery subtask done');

      throw Exception('Parent-level failure');
    });
  } catch (e) {
    print('Parent operation error: $e');
  }
}
