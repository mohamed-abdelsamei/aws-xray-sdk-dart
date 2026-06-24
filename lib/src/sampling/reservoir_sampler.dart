import 'dart:math';
import 'sampling_strategy.dart';

/// X-Ray reservoir sampling: [reservoirSize] requests/second always sampled,
/// then [fixedRate] above the reservoir.
///
/// The first [reservoirSize] requests in each calendar second are sampled
/// unconditionally; once the reservoir for that second is exhausted, each
/// further request is sampled independently with probability [fixedRate] (the
/// same coin flip [FixedRateSampler] uses). The reservoir resets each calendar
/// second, matching the X-Ray daemon reservoir algorithm. The [SamplingRequest]
/// is ignored — the decision depends only on volume and time.
///
/// **Clock safety:** the per-second window is measured with a monotonic
/// [Stopwatch], not the wall clock, so an NTP correction or VM suspend/resume
/// that moves `DateTime.now()` backward (or jumps it forward) cannot reset the
/// reservoir spuriously and over-sample, nor stall it. Time is read as elapsed
/// microseconds since the sampler was created.
///
/// **Isolate safety:** [_currentSecond] and [_takenThisSecond] are mutable
/// instance state. Each Dart isolate must create its own [ReservoirSampler]
/// (and its own [XRayTracer]); sharing an instance across isolates is not
/// supported and will produce incorrect sampling counts. The reservoir is
/// therefore *per isolate*, not per service — N isolates each admit up to
/// [reservoirSize] requests/second.
final class ReservoirSampler implements SamplingStrategy {
  /// Creates a reservoir sampler. [elapsedMicros] is an injectable monotonic
  /// time source (microseconds since some fixed origin) used only by tests;
  /// production uses an internal [Stopwatch].
  ReservoirSampler({
    this.reservoirSize = 50,
    this.fixedRate = 0.05,
    int Function()? elapsedMicros,
  }) : _elapsedMicros = elapsedMicros ?? _stopwatchClock();

  final int reservoirSize;
  final double fixedRate;
  final int Function() _elapsedMicros;

  /// Returns a monotonic clock closure backed by a single started [Stopwatch].
  static int Function() _stopwatchClock() {
    final sw = Stopwatch()..start();
    return () => sw.elapsedMicroseconds;
  }

  static final _rng = Random.secure();

  int _currentSecond = -1;
  int _takenThisSecond = 0;

  @override
  bool shouldSample(SamplingRequest request) {
    final second = _elapsedMicros() ~/ Duration.microsecondsPerSecond;
    if (second != _currentSecond) {
      _currentSecond = second;
      _takenThisSecond = 0;
    }

    if (_takenThisSecond < reservoirSize) {
      _takenThisSecond++;
      return true;
    }

    return _rng.nextDouble() < fixedRate;
  }
}
