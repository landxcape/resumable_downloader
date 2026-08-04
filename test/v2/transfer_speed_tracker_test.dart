import 'package:flutter_test/flutter_test.dart';
import 'package:resumable_downloader/src/v2/transfers/transfer_speed_tracker.dart';

void main() {
  test('returns null until two timed samples exist', () {
    final tracker = TransferSpeedTracker();

    expect(tracker.record(<int>[0], Duration.zero), isNull);
    expect(
      tracker.record(<int>[1000], const Duration(milliseconds: 500)),
      2000,
    );
  });

  test('aggregates multipart range bytes before calculating speed', () {
    final tracker = TransferSpeedTracker();

    tracker.record(<int>[100, 50], Duration.zero);
    expect(tracker.record(<int>[300, 250], const Duration(seconds: 1)), 400);
  });

  test('uses the one-second rolling sample window', () {
    final tracker = TransferSpeedTracker();

    tracker.record(<int>[0], Duration.zero);
    tracker.record(<int>[1000], const Duration(milliseconds: 500));
    expect(
      tracker.record(<int>[3000], const Duration(milliseconds: 1500)),
      2000,
    );
  });

  test('returns zero instead of a negative speed for non-advancing bytes', () {
    final tracker = TransferSpeedTracker();

    tracker.record(<int>[100], Duration.zero);
    expect(tracker.record(<int>[100], const Duration(milliseconds: 500)), 0);
    expect(tracker.record(<int>[90], const Duration(seconds: 1)), 0);
  });

  test('ignores samples without elapsed-time progress', () {
    final tracker = TransferSpeedTracker();

    tracker.record(<int>[0], Duration.zero);
    expect(tracker.record(<int>[100], Duration.zero), isNull);
  });

  test('reset clears the previous measurement', () {
    final tracker = TransferSpeedTracker();

    tracker.record(<int>[0], Duration.zero);
    expect(tracker.record(<int>[100], const Duration(seconds: 1)), 100);
    tracker.reset();
    expect(tracker.record(<int>[200], const Duration(seconds: 2)), isNull);
  });
}
