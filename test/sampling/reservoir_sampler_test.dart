import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:test/test.dart';

void main() {
  const req = SamplingRequest(
    serviceName: 'svc',
    httpMethod: 'GET',
    urlPath: '/api',
  );

  group('ReservoirSampler', () {
    test('always samples up to reservoirSize requests in the first second', () {
      final sampler = ReservoirSampler(reservoirSize: 5, fixedRate: 0.0);
      var sampled = 0;
      for (var i = 0; i < 5; i++) {
        if (sampler.shouldSample(req)) sampled++;
      }
      // All 5 should be within the reservoir
      expect(sampled, 5);
    });

    test('applies fixedRate above reservoir within one second', () {
      // Fill reservoir then check that requests above it follow the rate.
      final sampler = ReservoirSampler(reservoirSize: 2, fixedRate: 0.0);
      // Drain the reservoir.
      sampler.shouldSample(req);
      sampler.shouldSample(req);
      // Now above reservoir with rate=0 — none should be sampled.
      for (var i = 0; i < 20; i++) {
        expect(sampler.shouldSample(req), isFalse);
      }
    });

    test('reservoir resets each second', () async {
      final sampler = ReservoirSampler(reservoirSize: 1, fixedRate: 0.0);
      // Drain the reservoir in the first "second" (mocked via internal clock).
      expect(sampler.shouldSample(req), isTrue);
      expect(sampler.shouldSample(req), isFalse); // above reservoir, rate=0

      // Wait for the second to roll over.
      await Future.delayed(const Duration(seconds: 1));

      // Reservoir resets — first request in new second is sampled again.
      expect(sampler.shouldSample(req), isTrue);
    }, timeout: const Timeout(Duration(seconds: 3)));

    test('reservoirSize=0 falls through to fixedRate', () {
      final always = ReservoirSampler(reservoirSize: 0, fixedRate: 1.0);
      for (var i = 0; i < 20; i++) {
        expect(always.shouldSample(req), isTrue);
      }

      final never = ReservoirSampler(reservoirSize: 0, fixedRate: 0.0);
      for (var i = 0; i < 20; i++) {
        expect(never.shouldSample(req), isFalse);
      }
    });
  });
}
