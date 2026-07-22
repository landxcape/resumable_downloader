import 'download_status.dart';
import 'download_range_update.dart';

/// A snapshot of a V2 download task's lifecycle and aggregate transfer progress.
class DownloadUpdate {
  /// Creates a task lifecycle and progress snapshot.
  DownloadUpdate({
    required this.taskId,
    required this.status,
    required this.receivedBytes,
    this.totalBytes,
    this.activeRanges = 0,
    this.completedRanges = 0,
    this.retryAttempt = 0,
    this.outputPath,
    this.error,
    List<DownloadRangeUpdate> ranges = const <DownloadRangeUpdate>[],
  }) : ranges = List.unmodifiable(ranges),
       assert(receivedBytes >= 0),
       assert(totalBytes == null || totalBytes >= 0),
       assert(activeRanges >= 0),
       assert(completedRanges >= 0),
       assert(retryAttempt >= 0);

  /// Identifier of the task that emitted this update.
  final String taskId;

  /// Current task lifecycle state.
  final DownloadStatus status;

  /// Aggregate staged bytes received across all ranges.
  final int receivedBytes;

  /// Expected total bytes, or null when the server does not provide one.
  final int? totalBytes;

  /// Number of currently active HTTP ranges.
  final int activeRanges;

  /// Number of byte ranges that have completed.
  final int completedRanges;

  /// Current retry number when [status] is [DownloadStatus.retrying].
  final int retryAttempt;

  /// Final output path once the task has completed.
  final String? outputPath;

  /// Terminal or retry error associated with this update, when any.
  final Object? error;

  /// Per-range snapshots for multipart transfers.
  final List<DownloadRangeUpdate> ranges;

  /// Returns null when the server did not provide a usable total byte count.
  double? get progress {
    final total = totalBytes;
    if (total == null || total <= 0) {
      return null;
    }
    return (receivedBytes / total).clamp(0.0, 1.0).toDouble();
  }
}
