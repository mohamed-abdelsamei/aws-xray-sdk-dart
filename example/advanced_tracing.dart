// Example: structuring a trace — nested captureAsync vs. manual subsegments.
//
// Two complementary APIs:
//
//   * captureAsync(name, fn) — wraps a block as a subsegment and NESTS anything
//     traced inside it (manual subsegments and auto-instrumented HTTP/AWS calls
//     become its children). An uncaught error marks it faulted and rethrows.
//     Prefer this: it replaces the begin/end/fail bookkeeping below.
//
//   * beginSubsegment / endSubsegment / failSubsegment — the manual API for
//     flat sibling spans, or when begin and end straddle a callback boundary.
//     Manual spans attach under whatever scope is active when they open, so
//     inside captureAsync they nest under it; at the top level they are flat.

import 'package:aws_xray_sdk/aws_xray_sdk.dart';

void main() async {
  final tracer = XRayTracer(
    serviceName: 'order-service',
    sender: NoopSender(),
    sampling: FixedRateSampler(1.0),
  );

  await tracer.trace('process-order', () async {
    print('Trace: ${tracer.currentTraceId}');
    tracer.annotate('user_id', 'u-12345'); // indexed on the segment

    // ── captureAsync: a nested phase of work ──────────────────────────────
    // Everything traced inside the block becomes a child of 'checkout' in the
    // X-Ray timeline. Fault handling is automatic: an uncaught error marks
    // 'checkout' faulted and rethrows.
    await tracer.captureAsync('checkout', (span) async {
      span
        ..annotate('order_id', 'order-abc-123') // indexed, filterable
        ..addMetadata('items', 3); // non-indexed detail

      // A manual span opened here nests under 'checkout'.
      final inventory =
          tracer.beginSubsegment('inventory-check', namespace: 'aws');
      await Future.delayed(const Duration(milliseconds: 30));
      tracer.endSubsegment(inventory);
      print('  checkout/inventory OK');

      await tracer.captureAsync('charge-payment', (pay) async {
        pay.annotate('gateway', 'stripe');
        await Future.delayed(const Duration(milliseconds: 80));
        print('  checkout/charge-payment OK');
      });
    });

    // ── Manual API: a flat sibling span with explicit error handling ──────
    // Use this shape when the work can throw and you need the span to record
    // the failure but the code to continue (no rethrow), or when begin/end
    // don't share a scope.
    final persist = tracer.beginSubsegment('persist-order', namespace: 'local');
    try {
      await Future.delayed(const Duration(milliseconds: 25));
      tracer.endSubsegment(persist.addMetadata('table', 'orders'));
      print('  persist OK');
    } catch (e) {
      // Records the exception in 'cause' and sets fault=true.
      tracer.failSubsegment(persist, e);
      rethrow;
    }

    print('Order processed successfully');
  });

  // Resulting structure:
  //   process-order
  //     ├─ checkout
  //     │    ├─ inventory-check   (manual, nested under captureAsync)
  //     │    └─ charge-payment    (nested captureAsync)
  //     └─ persist-order          (manual, flat sibling)
  print('Segment closed and sent');
}
