/// Calculates a smoothed aggregate receive rate for one transfer attempt.
///
/// The caller supplies monotonic elapsed durations. Samples are retained over
/// a short rolling window so the reported rate does not follow every progress
/// callback immediately.
final class TransferSpeedTracker {
  TransferSpeedTracker({this.window = const Duration(seconds: 1)})
    : assert(window > Duration.zero);

  /// Duration of the rolling sample window.
  final Duration window;
  final List<_SpeedSample> _samples = <_SpeedSample>[];

  /// Records the aggregate bytes received by all ranges at [elapsed].
  ///
  /// Returns null until two samples with increasing elapsed time exist.
  double? record(Iterable<int> receivedBytes, Duration elapsed) {
    final aggregateBytes = receivedBytes.fold<int>(
      0,
      (sum, value) => sum + value,
    );
    assert(aggregateBytes >= 0);
    if (_samples.isNotEmpty && elapsed <= _samples.last.elapsed) {
      return null;
    }

    _samples.add(_SpeedSample(aggregateBytes, elapsed));
    final cutoff = elapsed - window;
    while (_samples.length > 2 && _samples[1].elapsed <= cutoff) {
      _samples.removeAt(0);
    }

    if (_samples.length < 2) {
      return null;
    }
    final oldest = _samples.first;
    final duration = elapsed - oldest.elapsed;
    if (duration <= Duration.zero) {
      return null;
    }
    final byteDelta = aggregateBytes - oldest.bytes;
    final elapsedSeconds =
        duration.inMicroseconds / Duration.microsecondsPerSecond;
    return (byteDelta < 0 ? 0 : byteDelta) / elapsedSeconds;
  }

  /// Clears all samples for the current transfer attempt.
  void reset() {
    _samples.clear();
  }
}

final class _SpeedSample {
  const _SpeedSample(this.bytes, this.elapsed);

  final int bytes;
  final Duration elapsed;
}
