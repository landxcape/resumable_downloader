import 'download_progress.dart';

/// Represents a single item in the download queue managed by [DownloadManager].
///
/// Each [QueueItem] contains the download [url], an optional [fileName], and an optional [progressCallback]
/// to receive updates on the progress of the download.
///
/// If [progressCallback] is provided, it will be invoked with a [Stream<double>]
/// that emits values between `0.0` (0%) and `1.0` (100%) as the download progresses.
///
/// Example:
/// ```dart
/// QueueItem(
///   url: 'https://example.com/file.zip',
///   fileName: 'example.zip', // optional
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

  /// An optional filename for the downloaded file. If not provided, the original URL is used.
  final String? fileName;

  /// An optional subdirectory for the downloaded file.
  /// If not provided, the file is downloaded to the default download directory set at initialization
  final String? subDir;

  /// An optional callback to receive a stream of download progress updates.
  ///
  /// The callback emits [DownloadProgress], representing the [DownloadProgress]
  /// of download completion.
  final void Function(DownloadProgress progress)? progressCallback;

  /// An optional callback to be invoked when the download completes
  final void Function()? onComplete;

  /// Creates a new [QueueItem] with the specified [url], an optional [fileName], and optional [progressCallback].
  /// if [fileName] is not provided, the original URL is used.
  /// If [subDir] is not provided, the file is downloaded to the default download directory set at initialization.
  /// [onComplete] is invoked when the download completes.
  QueueItem({
    required this.url,
    this.fileName,
    this.subDir,
    this.progressCallback,
    this.onComplete,
  });

  String get fileNameUrl => '${fileName == null ? '' : '$fileName-'}$url';
}
