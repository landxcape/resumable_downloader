import 'download_status.dart';

/// A snapshot of a V2 download task's lifecycle and aggregate transfer progress.
class DownloadUpdate {
  const DownloadUpdate({
    required this.taskId,
    required this.status,
    required this.receivedBytes,
    this.totalBytes,
    this.activeRanges = 0,
    this.completedRanges = 0,
    this.retryAttempt = 0,
    this.outputPath,
    this.error,
  })  : assert(receivedBytes >= 0),
        assert(totalBytes == null || totalBytes >= 0),
        assert(activeRanges >= 0),
        assert(completedRanges >= 0),
        assert(retryAttempt >= 0);

  final String taskId;
  final DownloadStatus status;
  final int receivedBytes;
  final int? totalBytes;
  final int activeRanges;
  final int completedRanges;
  final int retryAttempt;
  final String? outputPath;
  final Object? error;

  /// Returns null when the server did not provide a usable total byte count.
  double? get progress {
    final total = totalBytes;
    if (total == null || total <= 0) {
      return null;
    }
    return (receivedBytes / total).clamp(0.0, 1.0).toDouble();
  }
}
