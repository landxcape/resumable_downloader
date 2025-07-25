import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart'
    show getApplicationDocumentsDirectory;

import 'constants/enums.dart';
import 'constants/typedefs.dart';
import 'models/download_progress.dart';
import 'models/download_task.dart';
import 'models/log_record.dart';
import 'models/queue_item.dart';

// --- Download Manager ---

/// Manages concurrent file downloads with queuing, retries, progress reporting,
/// cancellation, and strategies for handling existing files.
///
/// Provides methods to request files ([getFile]), add downloads to a queue
/// ([addToQueue], [addAllToQueue]), cancel downloads ([cancelDownload], [cancelAll]),
/// and manage downloaded files ([deleteContentFile]).
///
/// It uses a base directory and an optional subdirectory to store downloads.
/// Concurrency limits and retry attempts are configurable. Logging can be enabled
/// via the optional [logger] callback.
class DownloadManager {
  /// The name of the subdirectory within the [_baseDirectory] where files will be stored.
  final String subDir;

  /// A completer that asynchronously resolves to the base directory used for downloads.
  /// If a custom [Directory] is provided, it will be used; otherwise, the manager will
  /// create and use a subdirectory inside the app's documents directory.
  /// The [subDir] will be created inside the resolved directory.
  final Completer<Directory> _baseDirectoryCompleter = Completer<Directory>();

  /// The maximum number of downloads that can run concurrently. Defaults to 3.
  final int maxConcurrentDownloads;

  /// The maximum number of times a failed download will be automatically retried. Defaults to 3.
  final int maxRetries;

  /// An optional callback function for logging messages from the manager.
  /// Receives records with a message string and a [LogLevel].
  final LogCallback? logger;

  /// The default strategy to use when a file already exists, applied if not
  /// specified per-download. Defaults to [FileExistsStrategy.resume].
  final FileExistsStrategy fileExistsStrategy; // Added strategy config

  /// A queue holding [DownloadTask]s waiting to be processed.
  final Queue<DownloadTask> _downloadQueue = Queue();

  /// A map tracking currently active download tasks, keyed by their URL.
  /// Used for quick lookup, status checks, and cancellation.
  // Store active tasks by URL for cancellation lookup
  final Map<String, DownloadTask> _activeDownloads = {};

  /// A flag indicating if the download queue is currently being processed.
  /// Prevents multiple concurrent processing loops.
  bool _isProcessing = false;

  /// A flag indicating whether the [dispose] method has been called.
  /// Prevents operations on a disposed manager instance.
  bool _isDisposed = false; // Flag to prevent operations after disposal
  /// The Dio instance used for network requests. Configured internally.
  final _dio = Dio();

  /// A Completer used to manage the asynchronous creation/verification of the
  /// target download subdirectory. Ensures it's only checked/created once initially.
  Completer<Directory>? _subdirectoryCompleter;

  /// A duration representing the delay between retries when a download task fails.
  Duration delayBetweenRetries;

  /// Creates a [DownloadManager] instance.
  ///
  /// - [subDir]: Required. The name of the subdirectory within [baseDirectory]
  ///   to store downloaded files.
  /// - [baseDirectory]: Optional. The parent directory for downloads. If omitted,
  ///   [Directory.systemTemp] is used.
  /// - [maxConcurrentDownloads]: Optional. The maximum number of simultaneous
  ///   downloads. Defaults to 3.
  /// - [maxRetries]: Optional. The maximum number of retry attempts for failed
  ///   downloads. Defaults to 3.
  /// - [logger]: Optional. A callback function ([LogCallback]) to receive logs.
  /// - [fileExistsStrategy]: Optional. The default strategy for handling existing
  ///   files. Defaults to [FileExistsStrategy.resume].
  DownloadManager({
    required this.subDir,
    Directory? baseDirectory,
    this.maxConcurrentDownloads = 3,
    this.maxRetries = 3,
    this.logger,
    this.fileExistsStrategy = FileExistsStrategy.resume, // Default strategy
    this.delayBetweenRetries = Duration.zero,
  }) {
    _initBaseDirectory(baseDirectory);

    /// Ensure base directory exists once
    _ensureBaseDirectoryExists();
  }

  void _initBaseDirectory(Directory? custom) async {
    try {
      if (custom != null) {
        _baseDirectoryCompleter.complete(custom);
        return;
      }

      final appDocDir = await getApplicationDocumentsDirectory();
      final dir = Directory('${appDocDir.path}/$subDir');

      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      _baseDirectoryCompleter.complete(dir);
    } catch (e) {
      _baseDirectoryCompleter.completeError(e);
    }
  }

  /// Internal helper. Ensures the base directory exists. Logs creation or errors.
  /// Called once during initialization.
  Future<void> _ensureBaseDirectoryExists() async {
    /// get base directory from completer
    final baseDirectory = await _baseDirectoryCompleter.future;
    try {
      if (!await baseDirectory.exists()) {
        await baseDirectory.create(recursive: true);
        _log('Created base directory: ${baseDirectory.path}');
      }
    } catch (e) {
      _log(
        'Failed to create base directory: ${baseDirectory.path}, Error: $e',
        level: LogLevel.error,
      );

      /// Re-throw or handle as critical failure? For now, log and continue.
    }
  }

  /// Verifies whether a fully downloaded file is valid by comparing its size
  /// to the expected `Content-Length` from a HEAD request.
  ///
  /// This method performs a HEAD request to the given [url] and retrieves the
  /// expected content length from the server. It then compares it to the actual
  /// size of the provided [file]. If they match, the file is considered valid.
  ///
  /// - Returns `true` if the file size matches the expected content length.
  /// - Returns `false` if the sizes mismatch or if the HEAD request fails.
  ///
  /// A warning log is emitted if:
  /// - The file size does not match the expected content length.
  /// - The HEAD request fails (e.g., due to network issues or server errors).
  ///
  /// If the HEAD request fails for any reason, the file is considered invalid
  /// by default as a safety measure.
  ///
  /// Example:
  /// ```dart
  /// final isValid = await _isDownloadedFileValid(url, File('/path/to/file'));
  /// if (!isValid) {
  ///   await file.delete(); // Optionally handle corruption
  /// }
  /// ```
  ///
  /// [url] - The original URL from which the file was downloaded.
  /// [file] - The downloaded file to validate.
  ///
  /// Throws no exceptions.
  Future<bool> _isDownloadedFileValid(String url, File file) async {
    try {
      final response = await _dio.head<dynamic>(
        url,
        options: Options(followRedirects: true),
      );
      final expectedLength = int.tryParse(
        response.headers.value(HttpHeaders.contentLengthHeader) ?? '',
      );
      final actualLength = await file.length();

      if (expectedLength != null && actualLength != expectedLength) {
        _log(
          'File size mismatch: expected $expectedLength, got $actualLength',
          level: LogLevel.warning,
        );
        return false;
      }

      return true;
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.connectionError) {
        _log(
          'Failed to verify downloaded file, Connection Error: $e',
          level: LogLevel.warning,
        );
        return true;
      }
      _log('Failed to verify downloaded file: $e', level: LogLevel.warning);
      // If we can't verify, we assume the worst.
      return false;
    }
  }

  /// Internal helper. Checks file existence, applies strategy, and creates/enqueues a task if needed.
  ///
  /// This function encapsulates the logic defined by [FileExistsStrategy] before
  /// actually queueing a download. It also handles returning existing tasks/futures
  /// if the download is already active or queued.
  /// Assumes the manager's `fileExistsStrategy` should be used.
  ///
  /// - [item]: The queue item to check and potentially download.
  /// - [progress]: Optional callback to receive the progress stream for this download.
  ///
  /// Returns a Future that completes with the [File] object (either existing or downloaded),
  /// or throws an error based on the strategy or download failures.
  /// Returns `null` specifically if cancelled very early or in edge cases handled internally.
  Future<File?> _checkFileAndCreateTask(
    QueueItem item, {
    bool moveToFront = false,
  }) async {
    final downloadUrl = item.url;
    final progress = item.progressCallback;

    final localPath = await _getDownloadPath(item);
    final existingFile = File(localPath);
    final tempFile = File('$localPath.tmp');
    final fileExists = await existingFile.exists(); // Check existence async
    final tempFileExists = await tempFile.exists(); // Check existence async

    if (fileExists) {
      final isValid = await _isDownloadedFileValid(downloadUrl, existingFile);
      if (isValid) {
        final fileLength = await existingFile.length();
        progress?.call(
          DownloadProgress(receivedByte: fileLength, totalByte: fileLength),
        );
        _log(
          'File already exists and is valid. Skipping download.',
          level: LogLevel.debug,
        );
      } else {
        _log('Corrupted file detected. Deleting.', level: LogLevel.warning);
        await existingFile.delete();
      }
    }

    if (fileExists || tempFileExists) {
      // NOTE: This logic applies the *manager's* default `fileExistsStrategy`.
      switch (fileExistsStrategy) {
        case FileExistsStrategy.keepExisting:
          if (fileExists) {
            // Only applies if the *final* file exists
            _log(
              'File already exists and strategy is keepExisting: $downloadUrl',
            );

            /// Provide progress stream that immediately completes? Or none? For now return existing file.
            /// If a stream was expected, this might need adjustment.
            return existingFile;
          }
          _log(
            'Temp file exists but strategy is keepExisting (applies to final file). Proceeding with download check: $downloadUrl',
            level: LogLevel.debug,
          );
          // If only temp file exists, proceed as if file doesn't exist for 'keepExisting'
          break;
        case FileExistsStrategy.fail:
          if (fileExists) {
            // Only applies if the *final* file exists
            _log(
              'File already exists and strategy is fail: $downloadUrl',
              level: LogLevel.error,
            );
            throw FileSystemException(
              'Download target file already exists and strategy is fail.',
              localPath,
            );
          }
          _log(
            'Temp file exists but strategy is fail (applies to final file). Proceeding with download check: $downloadUrl',
            level: LogLevel.debug,
          );
          // If only temp file exists, proceed as if file doesn't exist for 'fail'
          break;
        case FileExistsStrategy.replace:
          _log(
            'File/Temp exists and strategy is replace. Will overwrite: $downloadUrl',
            level: LogLevel.info,
          );
          // Actual deletion/overwrite handled in _download
          break; // Continue below to check active/queue
        case FileExistsStrategy.resume:
          if (fileExists) {
            // Final file exists, treat like keepExisting for resume
            _log(
              'File exists and strategy is resume. Returning existing file: $downloadUrl',
              level: LogLevel.info,
            );
            return existingFile;
          }
          // If only temp file exists, resume logic will be handled in _download
          _log(
            'Temp file exists and strategy is resume. Proceeding to download phase: $downloadUrl',
            level: LogLevel.info,
          );
          break; // Continue below to check active/queue
      }
    }

    /// If file doesn't exist OR strategy allows proceeding (replace/resume with temp/fail with temp/keepExisting with temp)
    /// Check if already active or queued
    if (_activeDownloads.containsKey(downloadUrl) ||
        _downloadQueue.any((t) => t.item.url == downloadUrl)) {
      _log(
        'Download already active or queued: $downloadUrl',
        level: LogLevel.info,
      );

      /// Find the existing task and return its future
      final existingTask =
          _activeDownloads[downloadUrl] ??
          _downloadQueue.firstWhere((t) => t.item.url == downloadUrl);

      if (moveToFront) {
        // If the task is in the queue, move it to the front
        if (_downloadQueue.contains(existingTask)) {
          _downloadQueue.remove(existingTask);
          _downloadQueue.addFirst(existingTask); // Move to the top
          _log(
            'Moved download to top of queue: $downloadUrl',
            level: LogLevel.info,
          );
        }
      }

      // /// Call progress callback if provided and task hasn't completed yet
      if (progress != null && !existingTask.progressController.isClosed) {
        existingTask.initProgressCallback();
      }
      return existingTask.completer.future;
    }

    /// Create and enqueue new task
    // Note: Task created with the *manager's* default strategy.
    final task = DownloadTask(item, fileExistsStrategy);
    task.initProgressCallback();
    _enqueue(task);
    _processQueue(); // Don't await

    return task.completer.future;
  }

  /// Retrieves a file, downloading it if necessary, based on the **manager's configured default strategy**.
  ///
  /// Checks if the file exists locally. Based on the manager's [fileExistsStrategy],
  /// it might return the existing file, download the file, or throw an error.
  /// ***Note: This method currently does not support overriding the strategy per call.***
  ///
  /// Provides a [progress] callback that delivers a stream for monitoring the download.
  ///
  /// - [QueuItem]: The queue item of the file to get. Must be a valid, absolute URL.
  /// - [progress]: Optional callback ([DownloadProgressRecord]) to receive the download
  ///   progress stream.
  ///
  /// Returns a [Future] that completes with the requested [File] or null.
  /// Throws a [StateError] if the manager is disposed.
  /// Throws a [FileSystemException] if strategy is [FileExistsStrategy.fail] and the file exists.
  /// Throws other exceptions (e.g., [DioException]) if the download fails.
  /// Asserts if [downloadUrl] is not a valid URL.
  Future<File?> getFile(QueueItem downloadItem) async {
    final downloadUrl = downloadItem.url;

    if (_isDisposed) {
      _log(
        'DownloadManager is disposed. Cannot get file: $downloadUrl',
        level: LogLevel.warning,
      );
      throw StateError('DownloadManager is disposed.');
    }
    assert(
      Uri.tryParse(downloadUrl)?.hasAbsolutePath == true,
      '[downloadUrl] must be a complete url.',
    );

    // Calls internal check which uses the manager's default strategy.
    return await _checkFileAndCreateTask(downloadItem, moveToFront: true);
  }

  /// Adds a URL to the download queue without waiting for completion.
  /// Honours the **manager's configured default FileExistsStrategy**.
  /// ***Note: This method currently does not support overriding the strategy per call.***
  ///
  /// This method checks the manager's [fileExistsStrategy] and queues the download if necessary.
  /// It does not return the downloaded file directly. Use [getFile] if you need the resulting [File] object.
  ///
  /// - [downloadItem]: The queue item of the file to queue. Must be a valid, absolute URL.
  /// - [progress]: Optional callback ([DownloadProgressRecord]) to receive the download
  ///   progress stream if the download is started.
  ///
  /// Returns a [Future] that completes when the task has been checked and potentially
  /// added to the queue (or handled according to the manager's strategy). It does *not* wait for the
  /// download itself to finish.
  /// Returns normally if the manager is disposed, but logs a warning.
  /// Asserts if [downloadUrl] is not a valid URL.
  ///
  /// NOTE: log printing [progress] will significantly impact download speed.
  Future<void> addToQueue(QueueItem downloadItem) async {
    final downloadUrl = downloadItem.url;

    if (_isDisposed) {
      _log(
        'DownloadManager is disposed. Cannot add to queue: $downloadUrl',
        level: LogLevel.warning,
      );
      return;
    }
    assert(
      Uri.tryParse(downloadItem.url)?.hasAbsolutePath == true,
      '[downloadUrl] must be a complete url.',
    );

    // Calls internal check which uses the manager's default strategy.
    // Ignores the returned Future<File?> as we only care about queueing or strategy handling.
    await _checkFileAndCreateTask(downloadItem);
  }

  /// Iterates through the list of download configurations and calls [addToQueue] for each.
  /// Allows specifying individual progress callbacks per download. The `strategy` field in the input records is ignored.
  ///
  /// - [downloadItems]: A list of records, where each record contains the [QueueItem],
  ///   an optional 'progress' callback ([DownloadProgressRecord]), and an optional 'strategy' ([FileExistsStrategy]) field **(which is currently ignored)**.
  ///
  /// Returns a [Future] that completes when all downloads in the list have been
  /// processed and potentially added to the queue based on the manager's default strategy.
  /// It does *not* wait for the downloads themselves to finish.
  /// Returns normally if the manager is disposed, but logs a warning.
  ///
  /// NOTE: log printing [progress] will significantly impact download speed.
  Future<void> addAllToQueue(List<QueueItem> downloadItems) async {
    if (_isDisposed) {
      _log(
        'DownloadManager is disposed. Cannot add all to queue.',
        level: LogLevel.warning,
      );
      return;
    }
    for (final item in downloadItems) {
      addToQueue(item);
    }
  }

  /// Internal helper. Adds a [DownloadTask] to the internal queue.
  /// Assumes duplicate checks and strategy handling have already occurred.
  Future<void> _enqueue(DownloadTask task) async {
    _downloadQueue.add(task);
    _log('Enqueued download: ${task.item.fileNameUrl}');
  }

  /// Internal helper. Processes the download queue, starting new downloads if slots are available.
  ///
  /// This method is the core loop that picks tasks from `_downloadQueue` and
  /// initiates their download via `_download`, respecting `maxConcurrentDownloads`.
  /// It ensures it doesn't run concurrently with itself using the `_isProcessing` flag.
  Future<void> _processQueue() async {
    if (_isProcessing || _isDisposed) return;

    /// Don't process if already processing or disposed
    _isProcessing = true;

    try {
      while (_downloadQueue.isNotEmpty &&
          _activeDownloads.length < maxConcurrentDownloads) {
        if (_isDisposed) break;

        /// Stop if disposed during processing

        final task = _downloadQueue.removeFirst();

        /// Double check if disposed before starting download
        if (_isDisposed) {
          _cleanupTask(
            task,
            StateError('DownloadManager disposed before download could start.'),
          );
          continue;
        }

        /// Check if cancelled before starting
        if (task.cancelToken.isCancelled) {
          _log(
            'Task was cancelled before starting: ${task.item.fileNameUrl}',
            level: LogLevel.warning,
          );
          _cleanupTask(
            task,
            DioException.requestCancelled(
              requestOptions: RequestOptions(path: task.item.url),
              reason: 'Cancelled before start',
            ),
          );
          continue;
        }

        _activeDownloads[task.item.url] = task;

        /// Add to active map
        _log('Starting download: ${task.item.fileNameUrl}');

        /// Don't await _download, let it run concurrently
        _download(task).catchError((Object e) {
          /// Catch potential synchronous errors in _download setup (unlikely but possible)
          _log(
            'Error initiating download for ${task.item.fileNameUrl}: $e',
            level: LogLevel.error,
          );
          if (!_activeDownloads.containsKey(task.item.url)) return;

          /// Already handled in finally?
          _activeDownloads.remove(task.item.url);
          _cleanupTask(task, e);
          _processQueue();

          /// Try processing next after error
        });
      }
    } finally {
      _isProcessing = false;

      /// If dispose was called while processing, ensure queue is cleared etc.
      if (_isDisposed) {
        _clearQueueAndCleanupTasks();
      }
    }
  }

  /// Internal helper. Performs the actual download using Dio for a given [DownloadTask].
  /// Handles network requests, progress updates, retries (based on status code), and final file operations.
  /// Uses the `fileExistsStrategy` stored within the `task`.
  Future<void> _download(DownloadTask task) async {
    if (task.cancelToken.isCancelled || _isDisposed) {
      /// Handle cases where cancellation happened just before download call
      _log(
        'Download cancelled or manager disposed just before Dio call: ${task.item.fileNameUrl}',
        level: LogLevel.warning,
      );
      _activeDownloads.remove(task.item.url);

      /// Ensure removed from active
      _cleanupTask(
        task,
        task.cancelToken.isCancelled
            ? DioException.requestCancelled(
              requestOptions: RequestOptions(path: task.item.url),
              reason: 'Cancelled before network request',
            )
            : StateError('DownloadManager disposed'),
      );
      _processQueue();

      /// Try next
      return;
    }

    String? localPath;

    /// Make nullable

    try {
      /// Ensure the target directory exists *just before* download
      final targetDirectory = await _getLocalDirectory();

      /// Get Directory object
      localPath =
          '${targetDirectory.path}/${_getFilenameFromQueueItem(task.item)}';
      final tempPath = '$localPath.tmp';
      final file = File(tempPath);
      // Check existence of TEMP file for resume/replace logic within download phase
      final tempFileExists =
          await file.exists(); // Use 'file' which points to tempPath

      /// If strategy is replace, explicitly delete existing TEMP file first for certainty
      /// (Dio might overwrite, but this is safer for consistency)
      // Note: The 'replace' strategy in _checkFileAndCreateTask allows proceeding even if final file exists.
      // Deleting the *temp* file here ensures a fresh start for the download itself.
      if (task.fileExistsStrategy == FileExistsStrategy.replace &&
          tempFileExists) {
        _log(
          'Explicitly deleting existing temp file for replacement: $tempPath',
          level: LogLevel.debug,
        );
        await file.delete();
      }

      // Determine start byte for potential resume
      final startByte =
          (task.fileExistsStrategy == FileExistsStrategy.resume &&
                  tempFileExists)
              ? await file.length()
              : 0;

      // Determine Dio's file access mode based on strategy
      final accessMode = switch (task.fileExistsStrategy) {
        FileExistsStrategy.replace => FileAccessMode.write,
        FileExistsStrategy.keepExisting =>
          FileAccessMode.write, // Should not be reached if file exists
        FileExistsStrategy.fail =>
          FileAccessMode.write, // Should not be reached if file exists
        FileExistsStrategy.resume =>
          FileAccessMode
              .append, // Append if resuming, otherwise write (startByte check handles this)
      };

      // Perform Dio download request
      await _dio.download(
        task.item.url,

        /// Save path (always temp first)
        tempPath,

        /// Pass the cancel token
        cancelToken: task.cancelToken,
        options: Options(
          headers:
              startByte > 0
                  ? {'Range': 'bytes=$startByte-'}
                  : null, // Add Range header for resume
          // Adjust response type if needed, default is usually Stream for download
          // responseType: ResponseType.stream, // Keep as default unless issues arise
        ),
        // Set file access mode based on strategy (mainly for resume vs replace)
        // NOTE: Dio's behavior with 'append' might vary. Testing recommended.
        // If startByte > 0, it implies resume, so append makes sense.
        // If startByte == 0, we want to overwrite the temp file, so write is correct.
        fileAccessMode: accessMode,
        onReceiveProgress: (received, total) {
          // Calculate total received considering potential resume offset
          final currentTotalReceived = startByte + received;
          // Use Dio's 'total' and add startByte for effective total size comparison
          final effectiveTotal = total > 0 ? startByte + total : -1;

          if (effectiveTotal > 0 &&
              !task.progressController.isClosed &&
              !task.cancelToken.isCancelled) {
            // Calculate progress based on total received / effective total size
            final downloadProgress = DownloadProgress(
              receivedByte: currentTotalReceived,
              totalByte: effectiveTotal,
            );
            task.progressController.add(downloadProgress);
          } else if (total == -1 && !task.progressController.isClosed) {
            /// Handle unknown total size - maybe emit bytes? Or a specific state?
            /// For now, let's not emit progress if total is unknown.
            _log(
              'Progress reporting skipped for ${task.item.fileNameUrl}: Total size unknown.',
              level: LogLevel.debug,
            );

            task.progressController.add(
              DownloadProgress(receivedByte: -1, totalByte: -1),
            ); // Example: Signal unknown size
          }
        },
        deleteOnError:
            fileExistsStrategy !=
            FileExistsStrategy
                .resume, // Consider Dio deleting partial file on Dio error
      );

      /// Check for cancellation *after* download completes (less likely but possible)
      if (task.cancelToken.isCancelled || _isDisposed) {
        _log(
          'Download cancelled or manager disposed during/after network request: ${task.item.fileNameUrl}',
          level: LogLevel.warning,
        );

        /// Delete potentially completed TEMP file if cancelled during operation
        try {
          await File(tempPath).delete(); // Use tempPath here
        } catch (_) {}
        throw DioException.requestCancelled(
          requestOptions: RequestOptions(path: task.item.url),
          reason: 'Cancelled during/after network request',
        );
      }

      _log('Download complete: ${task.item.fileNameUrl} -> $localPath');
      // Rename the successfully downloaded temp file to the final path
      if (!task.completer.isCompleted) {
        // Ensure final directory exists before renaming
        await Directory(localPath).parent.create(recursive: true);
        await file.rename(
          localPath,
        ); // Rename temp file (file variable) to final path (localPath)
        task.item.onComplete?.call();
        try {
          task.completer.complete(File(localPath));
        } catch (e) {
          _log('Failed to complete download: $e');
        }
      }
      // Ensure progress hits 1.0 and stream is closed on success
      if (!task.progressController.isClosed) {
        task.progressController.stream.last.then((lastProgress) {
          task.progressController.add(
            DownloadProgress(
              receivedByte: lastProgress.receivedByte,
              totalByte: lastProgress.totalByte,
            ),
          );
        });
        await Future<void>.delayed(Duration.zero);
        await task.progressController.close();
      }
    } on DioException catch (e, s) {
      if (CancelToken.isCancel(e)) {
        _log(
          'Download cancelled: ${task.item.fileNameUrl}',
          level: LogLevel.info,
        );

        /// Don't retry on explicit cancellation
        if (!task.completer.isCompleted) {
          // Complete with the specific cancellation error
          task.completer.completeError(e, s);
        }
        // Attempt to delete temp file on cancellation
        try {
          if (localPath != null) await File('$localPath.tmp').delete();
        } catch (_) {}
      } else {
        _log(
          'Download failed for ${task.item.fileNameUrl}: $e',
          level: LogLevel.error,
        );
        // Basic retry logic based on maxRetries count, regardless of error type
        if (task.retries < maxRetries && !_isDisposed) {
          await Future<void>.delayed(delayBetweenRetries);
          task.retries++;
          _log(
            'Retrying [${task.retries}/$maxRetries]: ${task.item.fileNameUrl}',
            level: LogLevel.warning,
          );

          /// Optional: Add delay before retry
          /// await Future.delayed(Duration(seconds: pow(2, task.retries).toInt()));
          _activeDownloads.remove(task.item.url); // Remove before re-queueing
          _downloadQueue.addFirst(task);

          /// Retry sooner: add to front
        } else {
          _log(
            'Exceeded retry limit or disposed for ${task.item.fileNameUrl}',
            level: LogLevel.error,
          );
          if (!task.completer.isCompleted) {
            task.completer.completeError(e, s); // Complete with the final error
          }
          // Optionally delete temp file on permanent failure
          // try { if (localPath != null) await File('$localPath.tmp').delete(); } catch(_) {}
        }
      }
    } catch (e, s) {
      /// Catch other potential errors (filesystem etc.)
      _log(
        'An unexpected error occurred during download or processing for ${task.item.fileNameUrl}: $e, $s',
        level: LogLevel.error,
      );
      if (!task.completer.isCompleted) {
        task.completer.completeError(e, s);
      }
      // Optionally delete temp file on unexpected failure
      // try { if (localPath != null) await File('$localPath.tmp').delete(); } catch(_) {}
    } finally {
      /// This block executes even if errors are thrown/caught above
      // Ensure task is removed from active list *unless* it was re-queued for retry
      if (_activeDownloads.containsKey(task.item.url)) {
        _activeDownloads.remove(task.item.url);
      }
      if (!task.progressController.isClosed) {
        task.progressController.close();

        /// Ensure controller is closed
      }

      /// Only process queue if not disposed and not re-queued for retry
      if (!_isDisposed && !_downloadQueue.contains(task)) {
        // Avoid double processing trigger if retrying
        _processQueue();

        /// Trigger processing for the next item
      }
    }
  }

  /// Cancels a specific download (if active or queued).
  ///
  /// If the download is currently active, it attempts to cancel the network request.
  /// If it's queued, it removes it from the queue.
  /// Completes the corresponding task's future with a cancellation error.
  ///
  /// - [url]: The URL of the download to cancel.
  ///
  /// Returns a [Future] that completes when the cancellation attempt is finished.
  /// Does nothing if the manager is disposed or the URL is not found.
  Future<void> cancelDownload(String url) async {
    if (_isDisposed) return;

    DownloadTask? taskToCancel;

    /// Check active downloads
    if (_activeDownloads.containsKey(url)) {
      taskToCancel = _activeDownloads[url];
      _log('Cancelling active download: $url');
      // Remove from active map *after* getting the task reference
      _activeDownloads.remove(url);
    } else {
      /// Check queued downloads
      taskToCancel = _downloadQueue.firstWhereOrNull(
        (task) => task.item.url == url,
      );
      if (taskToCancel != null) {
        _log('Removing and cancelling queued download: $url');
        _downloadQueue.remove(taskToCancel); // Remove from queue
      }
    }

    if (taskToCancel != null) {
      // Use helper to cancel token, close stream, and complete future with error
      _cleanupTask(
        taskToCancel,
        DioException.requestCancelled(
          requestOptions: RequestOptions(path: url),
          reason: 'User cancelled',
        ),
      );
      // Trigger queue processing in case an active slot was freed
      _processQueue();
    } else {
      _log('Could not find download to cancel: $url', level: LogLevel.warning);
    }
  }

  /// Cancels all active and queued downloads.
  ///
  /// Iterates through all active downloads, cancels their network requests,
  /// and removes them. Clears the download queue, cancelling any pending tasks.
  /// Completes all associated task futures with a cancellation error.
  ///
  /// Does nothing if the manager is disposed.
  void cancelAll() {
    if (_isDisposed) return;
    _log('Cancelling all active and queued downloads...');

    /// Cancel active downloads
    /// Create a copy of keys to avoid concurrent modification issues
    final activeUrls = _activeDownloads.keys.toList();
    for (final url in activeUrls) {
      final task = _activeDownloads.remove(url); // Remove from map first
      if (task != null) {
        _cleanupTask(
          task,
          DioException.requestCancelled(
            requestOptions: RequestOptions(path: url),
            reason: 'Cancel all requested',
          ),
        );
      }
    }
    // Ensure map is clear
    _activeDownloads.clear();

    /// Clear queue and cancel tasks
    _clearQueueAndCleanupTasks();

    _log('All downloads cancelled.');
    // Trigger queue processing once after clearing everything, mainly to ensure state consistency
    _processQueue();
  }

  /// Internal helper. Cleans up resources associated with a [DownloadTask].
  ///
  /// Cancels the Dio [CancelToken], closes the progress stream controller,
  /// and completes the task's [Completer] with the provided [error].
  /// Ensures these operations are safe even if already cancelled or closed.
  ///
  /// - [task]: The [DownloadTask] to clean up.
  /// - [error]: The error object (often a [DioException] for cancellations)
  ///   to complete the task's future with.
  /// - [stackTrace]: Optional stack trace associated with the error.
  void _cleanupTask(DownloadTask task, Object error, [StackTrace? stackTrace]) {
    if (!task.cancelToken.isCancelled) {
      try {
        task.cancelToken.cancel(error);

        /// Pass error info to cancel token if possible
      } catch (e) {
        _log(
          "Error cancelling task's token: ${task.item.fileNameUrl}, $e",
          level: LogLevel.error,
        );
      }
    }
    if (!task.progressController.isClosed) {
      task.progressController.close();
    }
    if (!task.completer.isCompleted) {
      task.completer.completeError(error, stackTrace);
    }
  }

  /// Internal helper. Clears the download queue and ensures all tasks within it are cleaned up.
  /// Used during `cancelAll` and `dispose`.
  void _clearQueueAndCleanupTasks() {
    while (_downloadQueue.isNotEmpty) {
      final task = _downloadQueue.removeFirst();
      _cleanupTask(
        task,
        DioException.requestCancelled(
          requestOptions: RequestOptions(path: task.item.url),
          reason: 'Queue cleared during cancel/dispose',
        ),
      );
    }
  }

  /// Internal helper. Gets the filename part from a URL.
  ///
  /// Uses basic string splitting. Might need refinement for complex URLs.
  /// Provides a default name if extraction fails.
  ///
  /// - [item]: The [QueueItem] to extract the filename from.
  ///
  /// Returns the extracted filename or a default placeholder.
  String _getFilenameFromQueueItem(QueueItem item) {
    try {
      final uri = Uri.parse(item.url);

      // Check query parameters for filename-ish values
      for (final entry in uri.queryParameters.entries) {
        final value = entry.value;
        if (value.contains('.') && !value.endsWith('.')) {
          final nameParts = value.split('.');
          return [item.fileName ?? nameParts.first, nameParts.last].join('.');
        }
      }

      // Check if last path segment looks like a file
      final segments = uri.pathSegments;
      if (segments.isNotEmpty) {
        final last = segments.last;
        if (last.contains('.') && !last.endsWith('/')) {
          final nameParts = last.split('.');
          return [item.fileName ?? nameParts.first, nameParts.last].join('.');
        }
      }

      // Default fallback
      return item.fileName ?? segments.last;
    } catch (_) {
      return item.fileName ?? DateTime.now().millisecondsSinceEpoch.toString();
    }
  }

  /// Internal helper. Gets the full *potential* local path for a download URL.
  /// Does not guarantee the file exists.
  ///
  /// Combines the base directory, subdirectory, and the filename extracted from the URL.
  /// Ensures the target directory exists before returning the path string.
  ///
  /// - [item]: The [QueueItem] to extract the filename from.
  ///
  /// Returns a [Future] that completes with the absolute local file path string.
  /// Throws if the subdirectory cannot be created/accessed.
  Future<String> _getDownloadPath(QueueItem item) async {
    /// Ensure target directory exists before returning path
    final directory = await _getLocalDirectory();
    return '${directory.path}/${_getFilenameFromQueueItem(item)}';
  }

  /// Internal helper. Gets the [Directory] object for the specific subdirectory where downloads are stored.
  ///
  /// Ensures the subdirectory ([_baseDirectory]/[subDir]) exists, creating it recursively
  /// if necessary. Uses a [Completer] (`_subdirectoryCompleter`) to avoid redundant
  /// checks/creation attempts.
  ///
  /// Returns a [Future] that completes with the [Directory] object.
  /// Throws a [FileSystemException] if the directory cannot be created or accessed.
  Future<Directory> _getLocalDirectory({String? subSubDir}) async {
    /// If completer exists and is not completed, wait for it
    if (_subdirectoryCompleter != null &&
        !_subdirectoryCompleter!.isCompleted) {
      return await _subdirectoryCompleter!.future;
    }

    /// If completer is null or completed, start/re-run the check/creation logic
    _subdirectoryCompleter = Completer<Directory>();

    /// get base directory from completer
    final baseDirectory = await _baseDirectoryCompleter.future;

    // Construct path using platform-specific separator
    final subdirectoryPath =
        '${baseDirectory.path}${Platform.pathSeparator}$subDir${subSubDir == null ? '' : '${Platform.pathSeparator}$subSubDir'}';
    final subdirectory = Directory(subdirectoryPath);
    try {
      if (!await subdirectory.exists()) {
        _log('Attempting to create download subdirectory: $subdirectoryPath');

        /// Log attempt
        await subdirectory.create(recursive: true);
        _log('Finished creating download subdirectory: $subdirectoryPath');

        /// Log success
      }

      /// Complete with the directory object
      // Check if already completed before completing again
      if (!_subdirectoryCompleter!.isCompleted) {
        _subdirectoryCompleter!.complete(subdirectory);
      }
    } catch (e, s) {
      // Catch stack trace as well
      _log(
        'Failed to create or access subdirectory: $subdirectoryPath, Error: $e',
        level: LogLevel.error,
      );

      /// Complete with an error
      // Check if already completed before completing with error
      if (!_subdirectoryCompleter!.isCompleted) {
        // Try to provide OSError if possible, otherwise wrap the error
        final osError =
            e is FileSystemException ? e.osError : OSError(e.toString(), 0);
        _subdirectoryCompleter!.completeError(
          FileSystemException(
            'Failed to create required subdirectory',
            subdirectoryPath,
            osError,
          ),
          s, // Pass stack trace
        );
      }

      /// Re-throw the exception so the download fails correctly
      rethrow;
    }
    return await _subdirectoryCompleter!.future;
  }

  /// Deletes the downloaded file corresponding to the URL, if it exists.
  /// Also attempts to delete the corresponding `.tmp` file.
  ///
  /// Calculates the expected local path for the URL and attempts to delete the file
  /// at that path and its `.tmp` variant. Logs the outcome.
  ///
  /// - [item]: The [QueueItem] whose corresponding downloaded file should be deleted.
  ///
  /// Returns a [Future] that completes when the deletion attempts are finished.
  /// Does not throw if the file doesn't exist. Catches and logs errors during deletion.
  /// Does nothing if the manager is disposed.
  Future<void> deleteContentFile(QueueItem item) async {
    if (_isDisposed) return;
    String?
    path; // Make nullable to handle potential errors in _getDownloadPath
    try {
      path = await _getDownloadPath(item);

      /// Get path first
      final file = File(path);
      final tempFile = File('$path.tmp'); // Check for temp file as well

      bool deletedFinal = false;
      if (await file.exists()) {
        /// Check async
        await file.delete();
        deletedFinal = true;
        _log('Deleted local file for ${item.fileNameUrl} at $path');
      }

      bool deletedTemp = false;
      if (await tempFile.exists()) {
        // Check async
        await tempFile.delete();
        deletedTemp = true;
        _log(
          'Deleted local temp file for ${item.fileNameUrl} at ${tempFile.path}',
        );
      }

      if (!deletedFinal && !deletedTemp) {
        _log(
          'Local file or temp file for ${item.fileNameUrl} not found for deletion at $path(.tmp)',
          level: LogLevel.debug,
        );
      }
      _activeDownloads.remove(item.url);
      _downloadQueue.removeWhere((task) => task.item == item);
    } catch (e) {
      _log(
        'Error deleting file(s) for ${item.fileNameUrl} (path: $path): $e',
        level: LogLevel.error,
      );

      /// Optionally rethrow or handle
    }
  }

  /// Deletes all files associated with the base directory and subdirectory. and deletes them recursively if specified.
  Future<void> deleteRecursive({String? subDir, bool recursive = true}) async {
    final dir = await _getLocalDirectory(subSubDir: subDir);
    return dir.deleteSync(recursive: recursive);
  }

  /// Disposes of the download manager, cancelling all downloads and releasing resources.
  ///
  /// Sets the manager to a disposed state, cancels all active and queued downloads,
  /// and closes the internal Dio HTTP client. After calling dispose, no further
  /// operations should be performed on this instance.
  ///
  /// Calling multiple times has no effect beyond the first call.
  ///
  /// Returns a [Future] that completes when disposal is finished. Currently returns `Future<void>`.
  Future<void> dispose() async {
    if (_isDisposed) return;
    _log('Disposing DownloadManager...');
    _isDisposed = true;

    /// Set flag immediately

    cancelAll();

    /// Cancel everything first

    /// Close the Dio client to release its resources
    _dio.close(force: true);

    /// Force close connections

    /// Ensure queue and active maps are clear (should be via cancelAll, but belt-and-suspenders)
    _downloadQueue.clear();
    _activeDownloads.clear();

    // Consider nullifying the completer if it might hold resources or references
    _subdirectoryCompleter = null;

    _log('DownloadManager disposed.');
  }

  /// Internal logging helper.
  ///
  /// Sends the log message and level to the provided [logger] callback,
  /// if one was configured. Prepends '[DownloadManager]' to the message.
  ///
  /// - [message]: The log message string.
  /// - [level]: The severity level ([LogLevel]) of the message. Defaults to [LogLevel.debug].
  void _log(String message, {LogLevel level = LogLevel.debug}) {
    /// Avoid logging if logger is null
    logger?.call(
      LogRecord(message: '[DownloadManager] $message', level: level),
    );
  }
}
