// Example: manual subsegments for fine-grained tracing.
//
// Shows how to bracket discrete units of work — database calls, external API
// calls, file processing — with beginSubsegment / endSubsegment / failSubsegment.
//
// Important: all subsegments opened inside tracer.run() end up as siblings in
// the final segment document (flat list under 'subsegments').  The SDK does not
// currently support true parent→child nesting within a single Zone; all spans
// share the same parent segment.
//
// To create a truly nested span, open a manual subsegment, do the work, then
// close it.  Multiple nested-looking spans will appear in chronological order
// in the X-Ray timeline view.

import 'package:aws_xray_sdk/aws_xray_sdk.dart';

void main() async {
  final tracer = XRayTracer(
    serviceName: 'order-service',
    sender: NoopSender(),
    sampling: FixedRateSampler(1.0),
  );

  final segment = Segment.begin(
    name: 'process-order',
    traceId: TraceId.generate(),
  ).annotate('user_id', 'u-12345');

  await tracer.run(segment, () async {
    print('Trace: ${segment.traceId}');

    // ── 1. Validate input ─────────────────────────────────────────────────
    final validationSub = tracer.beginSubsegment('validate-order');
    try {
      await Future.delayed(const Duration(milliseconds: 10));
      tracer.endSubsegment(
        validationSub
            .addMetadata('orderId', 'order-abc-123')
            .addMetadata('amountCents', 4999),
      );
      print('  validation OK');
    } catch (e) {
      tracer.failSubsegment(validationSub, e);
      rethrow;
    }

    // ── 2. Check inventory (simulated AWS call) ───────────────────────────
    // namespace='aws' marks this as an AWS service call in the service map.
    final inventorySub =
        tracer.beginSubsegment('inventory-check', namespace: 'aws');
    try {
      await Future.delayed(const Duration(milliseconds: 30));
      tracer.endSubsegment(inventorySub);
      print('  inventory OK');
    } catch (e) {
      tracer.failSubsegment(inventorySub, e);
      rethrow;
    }

    // ── 3. Charge payment gateway (remote call) ───────────────────────────
    // namespace='remote' marks this as an external HTTP call.
    final paymentSub =
        tracer.beginSubsegment('charge-payment', namespace: 'remote');
    try {
      await Future.delayed(const Duration(milliseconds: 80));
      tracer.endSubsegment(paymentSub);
      print('  payment OK');
    } catch (e) {
      // failSubsegment records the exception type and message in 'cause',
      // and sets fault=true on the subsegment.
      tracer.failSubsegment(paymentSub, e);
      rethrow;
    }

    // ── 4. Persist order (local / database) ───────────────────────────────
    final dbSub = tracer.beginSubsegment('persist-order', namespace: 'local');
    try {
      await Future.delayed(const Duration(milliseconds: 25));
      tracer.endSubsegment(dbSub);
      print('  persist OK');
    } catch (e) {
      tracer.failSubsegment(dbSub, e);
      rethrow;
    }

    print('Order processed successfully');
  });

  print('Segment closed — 4 subsegments sent to X-Ray daemon');
}
