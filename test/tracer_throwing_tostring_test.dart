import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:test/test.dart';

class _ThrowingToString implements Exception {
  @override
  String toString() => throw StateError('toString exploded');
}

void main() {
  test(
      'error with throwing toString escapes run unchanged and the '
      'segment is still sent with a fault and fallback message', () async {
    final sender = InMemorySender();
    final tracer = XRayTracer(
      serviceName: 'svc',
      sender: sender,
      sampling: FixedRateSampler(1.0),
    );
    final original = _ThrowingToString();

    Object? caught;
    try {
      await tracer.run(tracer.beginSegment(), () async => throw original);
    } catch (e) {
      caught = e;
    }

    expect(identical(caught, original), isTrue);
    expect(sender.segments, hasLength(1));
    final json = sender.segments.single.toJson();
    expect(json['fault'], isTrue);
    final ex = ((json['cause'] as Map)['exceptions'] as List).single as Map;
    expect(ex['type'], '_ThrowingToString');
    expect(ex['message'], '_ThrowingToString');
  });
}
