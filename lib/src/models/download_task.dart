// --- Download Task ---

import 'dart:async' show Completer, StreamController;
import 'dart:io' show File;

import 'package:dio/dio.dart' show CancelToken;

import '../../resumable_downloader.dart';

/// Represents an individual download operation managed internally by [DownloadManager].
///
/// This class holds the state for a single download, including its URL,
/// completion status, progress reporting, cancellation token, and retry count.
class DownloadTask {
  /// The [QueueItem] of the file to be downloaded.
  final QueueItem item;

  /// A [Completer] that resolves with the downloaded [File] on success,
  /// or completes with an error if the download fails or is cancelled.
  /// May complete with `null` in specific handled cases (though current logic aims for File or error).
  final Completer<File?> completer = Completer<File?>();

  /// A [StreamController] to broadcast download progress [DownloadProgress].
  /// It's a broadcast stream allowing multiple listeners if needed (e.g., via [getFile]).
  final StreamController<DownloadProgress> progressController =
      StreamController.broadcast();

  /// A callback function that can be set to handle progress updates for this task
  /// and sends to the [QueueItem]'s [progressCallback].
  void initProgressCallback() => progressController.stream.listen(
    (progress) => item.progressCallback?.call(progress),
  );

  /// A [CancelToken] from the `dio` package, used to cancel the underlying
  /// network request associated with this task.
  final CancelToken cancelToken = CancelToken(); // Added for cancellation
  /// The number of times this download has been retried after a failure.
  int retries = 0;

  /// The specific [FileExistsStrategy] applied to this download task.
  /// Determined when the task is created based on manager defaults or method parameters.
  FileExistsStrategy
  fileExistsStrategy; // Store strategy per task if needed, or use manager's default

  /// Creates a new download task instance.
  ///
  /// Requires the [item] [QueueItem] to download from and the [fileExistsStrategy] to apply for this specific task.
  DownloadTask(this.item, this.fileExistsStrategy);
}
