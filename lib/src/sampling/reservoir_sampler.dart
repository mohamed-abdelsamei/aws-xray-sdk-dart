import 'dart:math';
import 'sampling_strategy.dart';

/// X-Ray reservoir sampling: [reservoirSize] requests/second always sampled,
/// then [fixedRate] above the reservoir.
///
/// The reservoir resets each calendar second, matching the X-Ray daemon
/// reservoir algorithm.
final class ReservoirSampler implements SamplingStrategy {
  ReservoirSampler({
    this.reservoirSize = 50,
    this.fixedRate = 0.05,
  });

  final int reservoirSize;
  final double fixedRate;

  static final _rng = Random.secure();

  int _currentSecond = 0;
  int _takenThisSecond = 0;

  @override
  bool shouldSample(SamplingRequest request) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (now != _currentSecond) {
      _currentSecond = now;
      _takenThisSecond = 0;
    }

    if (_takenThisSecond < reservoirSize) {
      _takenThisSecond++;
      return true;
    }

    return _rng.nextDouble() < fixedRate;
  }
}
