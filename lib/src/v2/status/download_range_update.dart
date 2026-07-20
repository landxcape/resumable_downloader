import 'download_status.dart';

/// Progress and lifecycle data for one inclusive byte range in a V2 task.
class DownloadRangeUpdate {
  const DownloadRangeUpdate({
    required this.startByte,
    required this.endByte,
    required this.receivedBytes,
    required this.status,
  }) : assert(startByte >= 0),
       assert(endByte >= startByte),
       assert(receivedBytes >= 0),
       assert(receivedBytes <= endByte - startByte + 1);

  final int startByte;
  final int endByte;
  final int receivedBytes;
  final DownloadStatus status;

  int get totalBytes => endByte - startByte + 1;
  double get progress =>
      (receivedBytes / totalBytes).clamp(0.0, 1.0).toDouble();
}
