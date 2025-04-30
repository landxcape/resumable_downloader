import 'enums.dart';

/// A callback function type for receiving log messages from the [DownloadManager].
///
/// Provides a record containing the log [message] string and its severity [level].
typedef LogCallback =
    void Function(({String message, LogLevel level}) logRecord);

/// A callback function type for receiving download progress streams.
///
/// Provides a record containing the original download [url] and a [progressStream]
/// that emits values between 0.0 (0%) and 1.0 (100%) representing the download progress.
/// The stream closes upon completion or error of the specific download.
///
/// NOTE: Progress is only emitted if the server provides a total size (`Content-Length` > 0).
typedef DownloadProgressRecord =
    void Function(({String url, Stream<double> progressStream}) progressRecord);

/// A record representing a download queue item.
///
/// Contains the download [url] and an optional [progress] callback that can be used to
/// track and report the download's progress through a stream. The [progress] callback
/// emits progress updates as a percentage (from 0.0 to 1.0) of the download completion.
///
/// The `QueueItem` is primarily used to manage items in the download queue and keep track
/// of their progress during download.
///
/// - [url] : The URL of the file to be downloaded.
/// - [progress] : An optional callback function that provides a stream of progress updates.
///                The progress is reported as a value between 0.0 (0%) and 1.0 (100%) and can be
///                used for UI updates or logging during the download process.
typedef QueueItem = ({String url, DownloadProgressRecord? progress});
