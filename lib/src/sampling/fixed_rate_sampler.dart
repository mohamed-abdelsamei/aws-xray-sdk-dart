import 'dart:math';
import 'sampling_strategy.dart';

/// Samples a fixed fraction of requests at random.
final class FixedRateSampler implements SamplingStrategy {
  FixedRateSampler(this.rate)
      : assert(rate >= 0.0 && rate <= 1.0, 'rate must be between 0.0 and 1.0');

  /// Fraction of requests to sample (0.0 = none, 1.0 = all).
  final double rate;

  static final _rng = Random.secure();

  @override
  bool shouldSample(SamplingRequest request) => _rng.nextDouble() < rate;
}
