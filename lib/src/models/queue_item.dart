/// Represents a single item in the download queue managed by [DownloadManager].
///
/// Each [QueueItem] contains the download [url] and an optional [progressCallback]
/// to receive updates on the progress of the download.
///
/// If [progressCallback] is provided, it will be invoked with a [Stream<double>]
/// that emits values between `0.0` (0%) and `1.0` (100%) as the download progresses.
///
/// Example:
/// ```dart
/// QueueItem(
///   url: 'https://example.com/file.zip',
///   progressCallback: (stream) {
///     stream.listen((progress) {
///       print('Progress: ${(progress * 100).toStringAsFixed(1)}%');
///     });
///   },
/// );
/// ```
class QueueItem {
  /// The full URL of the file to be downloaded.
  final String url;

  /// An optional callback to receive a stream of download progress updates.
  ///
  /// The stream emits values between `0.0` and `1.0`, representing the percentage
  /// of download completion. The stream closes when the download completes or fails.
  final void Function(Stream<double> progressStream)? progressCallback;

  /// Creates a new [QueueItem] with the specified [url] and optional [progressCallback].
  QueueItem({required this.url, this.progressCallback});
}
