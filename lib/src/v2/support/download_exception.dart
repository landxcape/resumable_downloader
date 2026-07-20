/// Base class for terminal V2 download failures.
class DownloadException implements Exception {
  const DownloadException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => '$runtimeType: $message';
}

/// The caller intentionally stopped a task.
class DownloadCancelledException extends DownloadException {
  const DownloadCancelledException() : super('Download was cancelled');
}
