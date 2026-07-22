import 'download_status.dart';

/// Progress and lifecycle data for one inclusive byte range in a V2 task.
class DownloadRangeUpdate {
  /// Creates a progress snapshot for an inclusive byte range.
  const DownloadRangeUpdate({
    required this.startByte,
    required this.endByte,
    required this.receivedBytes,
    required this.status,
  }) : assert(startByte >= 0),
       assert(endByte >= startByte),
       assert(receivedBytes >= 0),
       assert(receivedBytes <= endByte - startByte + 1);

  /// First byte position in the inclusive range.
  final int startByte;

  /// Last byte position in the inclusive range.
  final int endByte;

  /// Number of bytes received within this range.
  final int receivedBytes;

  /// Current state of this range.
  final DownloadStatus status;

  /// Total byte length of this inclusive range.
  int get totalBytes => endByte - startByte + 1;

  /// Fraction of this range received, from 0.0 through 1.0.
  double get progress =>
      (receivedBytes / totalBytes).clamp(0.0, 1.0).toDouble();
}
