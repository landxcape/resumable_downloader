// --- Download Task ---

import 'dart:async' show Completer, StreamController;
import 'dart:io' show File;

import 'package:dio/dio.dart' show CancelToken;
import '../constants/enums.dart';

/// Represents an individual download operation managed internally by [DownloadManager].
///
/// This class holds the state for a single download, including its URL,
/// completion status, progress reporting, cancellation token, and retry count.
class DownloadTask {
  /// The URL of the file to be downloaded.
  final String url;

  /// A [Completer] that resolves with the downloaded [File] on success,
  /// or completes with an error if the download fails or is cancelled.
  /// May complete with `null` in specific handled cases (though current logic aims for File or error).
  final Completer<File?> completer = Completer<File?>();

  /// A [StreamController] to broadcast download progress (0.0 to 1.0).
  /// It's a broadcast stream allowing multiple listeners if needed (e.g., via [getFile]).
  final StreamController<double> progressController =
      StreamController.broadcast();

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
  /// Requires the [url] to download from and the [fileExistsStrategy] to apply for this specific task.
  DownloadTask(this.url, this.fileExistsStrategy); // Pass strategy
}
