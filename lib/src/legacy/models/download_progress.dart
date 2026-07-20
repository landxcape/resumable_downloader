/// Represents the current state of a download operation.
/// [receivedByte] is the number of bytes already downloaded,
/// and [totalByte] is the total number of bytes expected to be downloaded.
/// The [progress] property returns this ratio as a double between 0.0 and 1.0.
/// The [receivedKB] and [totalKB] properties return Kilobytes
/// The [receivedMB] and [totalMB] properties return megabytes
/// The [receivedGB] and [totalGB] properties return gigabytes
class DownloadProgress {
  /// The number of bytes already downloaded.
  final int receivedByte;

  /// The total number of bytes expected to be downloaded.
  final int totalByte;
  const DownloadProgress({required this.receivedByte, required this.totalByte});

  /// Calculates the download progress as a ratio between 0 and 1.0.
  double get progress => (receivedByte / totalByte).clamp(0.0, 1.0);

  /// Converts the download progress to kilobytes.
  double get receivedKB => receivedByte / 1024;
  double get totalKB => totalByte / 1024;

  /// Converts the download progress to megabytes.
  double get receivedMB => receivedKB / 1024;
  double get totalMB => totalKB / 1024;

  /// Converts the download progress to gigabytes.
  double get receivedGB => receivedMB / 1024;
  double get totalGB => totalMB / 1024;
}

/// Extension for [DownloadProgress] that provides additional methods for converting
/// the download progress into different units String. For example, it can convert the
/// download progress into kilobytes, megabytes, or gigabytes.
extension DownloadProgressExtension on DownloadProgress {
  /// Converts the download progress to a string representing the percentage.
  String getProgressPercent({int fractionDigits = 2}) =>
      (progress * 100).toStringAsFixed(fractionDigits);

  /// Converts the download progress to a string representing the kilobytes.
  String getReceivedKB({int fractionDigits = 2}) =>
      receivedKB.toStringAsFixed(fractionDigits);
  String getTotalKB({int fractionDigits = 2}) =>
      (totalKB).toStringAsFixed(fractionDigits);

  /// Converts the download progress to a string representing the megabytes.
  String getReceivedMB({int fractionDigits = 2}) =>
      (receivedMB).toStringAsFixed(fractionDigits);
  String getTotalMB({int fractionDigits = 2}) =>
      (totalMB).toStringAsFixed(fractionDigits);

  /// Converts the download progress to a string representing the gigabytes.
  String getReceivedGB({int fractionDigits = 2}) =>
      (receivedGB).toStringAsFixed(fractionDigits);
  String getTotalGB({int fractionDigits = 2}) =>
      (totalGB).toStringAsFixed(fractionDigits);
}
