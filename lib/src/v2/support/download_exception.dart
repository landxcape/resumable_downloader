/// Base class for terminal V2 download failures.
class DownloadException implements Exception {
  /// Creates a typed download failure with an optional underlying [cause].
  const DownloadException(this.message, {this.cause});

  /// Human-readable description of the failure.
  final String message;

  /// Original error, when V2 can retain one safely.
  final Object? cause;

  @override
  String toString() => '$runtimeType: $message';
}

/// The caller intentionally stopped a task.
class DownloadCancelledException extends DownloadException {
  /// Creates the cancellation failure reported after a caller cancels a task.
  const DownloadCancelledException() : super('Download was cancelled');
}

/// The server returned an HTTP status that prevents the transfer continuing.
class DownloadHttpException extends DownloadException {
  /// Creates an HTTP failure for [statusCode].
  const DownloadHttpException(this.statusCode, {String? message})
    : super(message ?? 'Unexpected HTTP status $statusCode');

  /// HTTP status code returned by the server.
  final int statusCode;
}

/// The server response did not satisfy the downloader's HTTP contract.
class DownloadProtocolException extends DownloadException {
  /// Creates a protocol failure with an explanation of the invalid response.
  const DownloadProtocolException(super.message);
}

/// The downloaded bytes could not be validated before finalization.
class DownloadIntegrityException extends DownloadException {
  /// Creates an integrity failure with an explanation of the failed validation.
  const DownloadIntegrityException(super.message);
}

/// A configured [DownloadValidator] rejected a file or could not complete.
class DownloadValidationException extends DownloadException {
  /// Creates a custom-validation failure with an optional original [cause].
  const DownloadValidationException(super.message, {super.cause});
}
