import 'dart:math';
import 'sampling_strategy.dart';

/// Samples a fixed fraction of requests at random.
///
/// Every request is sampled independently with probability [rate], using a
/// cryptographically-seeded [Random.secure] — there is no reservoir, no
/// per-second guarantee, and no request-property awareness (the
/// [SamplingRequest] is ignored). `FixedRateSampler(0.0)` samples nothing;
/// `FixedRateSampler(1.0)` samples everything (useful while verifying a setup).
///
/// Because each call is an independent coin flip, low rates over low traffic
/// can yield streaks of unsampled requests; use [ReservoirSampler] when you
/// need at least N traces per second regardless of rate.
final class FixedRateSampler implements SamplingStrategy {
  FixedRateSampler(this.rate)
      : assert(rate >= 0.0 && rate <= 1.0, 'rate must be between 0.0 and 1.0');

  /// Fraction of requests to sample (0.0 = none, 1.0 = all).
  final double rate;

  static final _rng = Random.secure();

  @override
  bool shouldSample(SamplingRequest request) => _rng.nextDouble() < rate;
}
