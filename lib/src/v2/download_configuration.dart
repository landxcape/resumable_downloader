/// Limits used by a [DownloadManager] to schedule file transfers and ranges.
class DownloadConfiguration {
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

  final int maxConcurrentDownloads;
  final int maxConcurrentConnections;
  final int maxConnectionsPerDownload;
  final int minimumBytesPerPart;
  final int maxRetries;
  final Duration retryDelay;
  final int checkpointBytes;
}
