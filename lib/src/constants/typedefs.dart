import '../models/log_record.dart';

/// A callback used by the [DownloadManager] to emit log messages.
///
/// The callback provides a [LogRecord] which contains the message and its severity.
typedef LogCallback = void Function(LogRecord log);
