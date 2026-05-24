import 'dart:math';
import 'sampling_strategy.dart';

/// X-Ray reservoir sampling: [reservoirSize] requests/second always sampled,
/// then [fixedRate] above the reservoir.
///
/// The reservoir resets each calendar second, matching the X-Ray daemon
/// reservoir algorithm.
///
/// **Isolate safety:** [_currentSecond] and [_takenThisSecond] are mutable
/// instance state. Each Dart isolate must create its own [ReservoirSampler]
/// (and its own [XRayTracer]); sharing an instance across isolates is not
/// supported and will produce incorrect sampling counts.
final class ReservoirSampler implements SamplingStrategy {
  ReservoirSampler({
    this.reservoirSize = 50,
    this.fixedRate = 0.05,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final int reservoirSize;
  final double fixedRate;
  final DateTime Function() _now;

  static final _rng = Random.secure();

  int _currentSecond = 0;
  int _takenThisSecond = 0;

  @override
  bool shouldSample(SamplingRequest request) {
    final now = _now().millisecondsSinceEpoch ~/ 1000;
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
