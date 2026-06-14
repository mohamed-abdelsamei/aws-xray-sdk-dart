// Example: manual instrumentation for non-AWS code.
//
// Shows annotations, metadata, SQL subsegments, and custom sampling
// without any AWS SDK client involved.

import 'package:aws_xray_sdk/aws_xray_sdk.dart';

final _tracer = XRayTracer(
  serviceName: 'payment-service',
  sender: NoopSender(),
  sampling: ReservoirSampler(reservoirSize: 50, fixedRate: 0.05),
);

Future<void> main() async {
  await processPayment(
    orderId: 'order-abc-123',
    amountCents: 4999,
    userId: 'user-xyz-789',
  );
}

Future<void> processPayment({
  required String orderId,
  required int amountCents,
  required String userId,
}) async {
  // Build the segment with known context before running.
  final segment = _tracer
      .beginSegment(user: userId)
      .annotate('order_id', orderId)
      .annotate('currency', 'USD');

  await _tracer.run(segment, () async {
    print('Processing payment for order $orderId');

    // 1. Validate payment — local subsegment.
    final validationSub = _tracer.beginSubsegment('validate-payment');
    try {
      await _validatePayment(amountCents);
      _tracer.endSubsegment(validationSub);
    } catch (e) {
      _tracer.failSubsegment(validationSub, e);
      rethrow;
    }

    // 2. Persist to database — SQL subsegment.
    final dbSub =
        _tracer.beginSubsegment('persist-payment', namespace: 'local');
    try {
      await _persistToDatabase(orderId, amountCents);
      _tracer.endSubsegment(dbSub);
    } catch (e) {
      _tracer.failSubsegment(dbSub, e);
      rethrow;
    }

    // 3. Emit event — remote subsegment.
    final eventSub = _tracer.beginSubsegment('emit-event', namespace: 'remote');
    try {
      await _emitPaymentEvent(orderId);
      _tracer.endSubsegment(eventSub);
    } catch (e) {
      _tracer.failSubsegment(eventSub, e);
      rethrow;
    }

    print('Payment processed successfully');
  });
}

Future<void> _validatePayment(int amountCents) async {
  if (amountCents <= 0) throw ArgumentError('Amount must be positive');
  await Future.delayed(const Duration(milliseconds: 5));
}

Future<void> _persistToDatabase(String orderId, int amountCents) async {
  // In a real app you'd annotate the subsegment with the DB call's metadata.
  await Future.delayed(const Duration(milliseconds: 20));
  print('  Persisted: $orderId = \$${amountCents / 100}');
}

Future<void> _emitPaymentEvent(String orderId) async {
  await Future.delayed(const Duration(milliseconds: 10));
  print('  Event emitted for $orderId');
}
