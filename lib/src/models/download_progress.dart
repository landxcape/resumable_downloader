/// Represents the current state of a download operation.
/// [receivedByte] is the number of bytes already downloaded,
/// and [totalByte] is the total number of bytes expected to be downloaded.
/// The [progress] property returns this ratio as a double between 0.0 and 1.0.
class DownloadProgress {
  /// The number of bytes already downloaded.
  final int receivedByte;

  /// The total number of bytes expected to be downloaded.
  final int totalByte;
  const DownloadProgress({required this.receivedByte, required this.totalByte});

  /// Calculates the download progress as a ratio between 0 and 1.0.
  double get progress => (receivedByte / totalByte).clamp(0.0, 1.0);
}
