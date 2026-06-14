import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:test/test.dart';

/// A fake clock that returns a fixed [DateTime] and can be advanced.
final class _FakeClock {
  _FakeClock(this._now);

  DateTime _now;

  DateTime call() => _now;

  void advance(Duration d) => _now = _now.add(d);
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
      final clock = _FakeClock(DateTime.utc(2024, 1, 1));
      final sampler = ReservoirSampler(
        reservoirSize: 1,
        fixedRate: 0.0,
        now: clock.call,
      );
      expect(sampler.shouldSample(req), isTrue); // second 1, reservoir used
      expect(sampler.shouldSample(req), isFalse); // second 1, above reservoir

      clock.advance(const Duration(seconds: 1));
      expect(sampler.shouldSample(req), isTrue); // second 2, reservoir reset
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
