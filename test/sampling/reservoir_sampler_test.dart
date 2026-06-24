import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:test/test.dart';

/// A fake monotonic clock (microseconds) that can be advanced. Mirrors the
/// `elapsedMicros` seam — production uses a [Stopwatch], which never moves
/// backward.
final class _FakeClock {
  int _micros = 0;

  int call() => _micros;

  void advance(Duration d) => _micros += d.inMicroseconds;
}

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
      expect(sampled, 5);
    });

    test('applies fixedRate above reservoir within one second', () {
      final sampler = ReservoirSampler(reservoirSize: 2, fixedRate: 0.0);
      sampler.shouldSample(req);
      sampler.shouldSample(req);
      for (var i = 0; i < 20; i++) {
        expect(sampler.shouldSample(req), isFalse);
      }
    });

    test('reservoir resets each second', () {
      final clock = _FakeClock();
      final sampler = ReservoirSampler(
        reservoirSize: 1,
        fixedRate: 0.0,
        elapsedMicros: clock.call,
      );
      expect(sampler.shouldSample(req), isTrue); // second 1, reservoir used
      expect(sampler.shouldSample(req), isFalse); // second 1, above reservoir

      clock.advance(const Duration(seconds: 1));
      expect(sampler.shouldSample(req), isTrue); // second 2, reservoir reset
    });

    test('a sub-second advance does not reset the reservoir', () {
      final clock = _FakeClock();
      final sampler = ReservoirSampler(
        reservoirSize: 1,
        fixedRate: 0.0,
        elapsedMicros: clock.call,
      );
      expect(sampler.shouldSample(req), isTrue); // reservoir used
      clock.advance(const Duration(milliseconds: 500)); // still same second
      expect(sampler.shouldSample(req), isFalse);
    });

    test('monotonic clock never moves backward, so no spurious reset (H4)', () {
      // The injected seam models a Stopwatch: time only advances. Even a tiny
      // forward step that lands in the same whole second must not reset; a
      // backward step is impossible with the production Stopwatch, so the
      // wall-clock over-sampling failure mode cannot occur.
      final clock = _FakeClock();
      final sampler = ReservoirSampler(
        reservoirSize: 1,
        fixedRate: 0.0,
        elapsedMicros: clock.call,
      );
      expect(sampler.shouldSample(req), isTrue); // second 0, reservoir used

      // Many sub-second ticks within the same second: reservoir stays exhausted.
      for (var i = 0; i < 10; i++) {
        clock.advance(const Duration(milliseconds: 50));
        expect(sampler.shouldSample(req), isFalse,
            reason: 'no reset within the same monotonic second');
      }

      // Cross into the next second: exactly one reset, one admit.
      clock.advance(const Duration(milliseconds: 600)); // total > 1s
      expect(sampler.shouldSample(req), isTrue);
    });

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
