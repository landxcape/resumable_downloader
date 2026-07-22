/// Limits used by a [DownloadManager] to schedule file transfers and ranges.
class DownloadConfiguration {
  /// Creates transfer limits, retry behavior, and checkpoint granularity.
  DownloadConfiguration({
    this.maxConcurrentDownloads = 3,
    this.maxConcurrentConnections = 6,
    this.maxConnectionsPerDownload = 4,
    this.minimumBytesPerPart = 8 * 1024 * 1024,
    this.maxRetries = 3,
    this.retryDelay = const Duration(milliseconds: 250),
    this.checkpointBytes = 1024 * 1024,
  }) {
    if (maxConcurrentDownloads <= 0) {
      throw ArgumentError.value(
        maxConcurrentDownloads,
        'maxConcurrentDownloads',
        'must be greater than zero',
      );
    }
    if (maxConcurrentConnections <= 0) {
      throw ArgumentError.value(
        maxConcurrentConnections,
        'maxConcurrentConnections',
        'must be greater than zero',
      );
    }
    if (maxConnectionsPerDownload <= 0) {
      throw ArgumentError.value(
        maxConnectionsPerDownload,
        'maxConnectionsPerDownload',
        'must be greater than zero',
      );
    }
    if (minimumBytesPerPart <= 0) {
      throw ArgumentError.value(
        minimumBytesPerPart,
        'minimumBytesPerPart',
        'must be greater than zero',
      );
    }
    if (maxRetries < 0) {
      throw ArgumentError.value(
        maxRetries,
        'maxRetries',
        'must not be negative',
      );
    }
    if (retryDelay.isNegative) {
      throw ArgumentError.value(
        retryDelay,
        'retryDelay',
        'must not be negative',
      );
    }
    if (checkpointBytes <= 0) {
      throw ArgumentError.value(
        checkpointBytes,
        'checkpointBytes',
        'must be greater than zero',
      );
    }
  }

  /// Maximum number of files allowed to transfer concurrently.
  final int maxConcurrentDownloads;

  /// Maximum number of HTTP requests shared by all managed downloads.
  final int maxConcurrentConnections;

  /// Maximum number of HTTP requests assigned to one file.
  final int maxConnectionsPerDownload;

  /// Smallest part size used when a server supports multipart range requests.
  final int minimumBytesPerPart;

  /// Number of retries after an initial transient transport failure.
  final int maxRetries;

  /// Delay between transient retry attempts.
  final Duration retryDelay;

  /// Bytes written between durable progress-manifest checkpoints.
  final int checkpointBytes;
}
