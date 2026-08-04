import 'download_update.dart';

/// Aggregate transfer metrics for one logical download operation.
class DownloadOperationMetrics {
  /// Creates an immutable operation metrics snapshot.
  DownloadOperationMetrics({
    required this.operationId,
    required this.receivedBytes,
    required this.totalBytes,
    required this.bytesPerSecond,
    required Iterable<String> taskIds,
    required Map<String, DownloadUpdate> taskUpdates,
  }) : taskIds = List<String>.unmodifiable(taskIds),
       taskUpdates = Map<String, DownloadUpdate>.unmodifiable(taskUpdates),
       assert(receivedBytes >= 0),
       assert(totalBytes == null || totalBytes >= 0),
       assert(bytesPerSecond == null || bytesPerSecond >= 0);

  /// Identifier of the operation that produced this snapshot.
  final String operationId;

  /// Aggregate bytes received by the operation's unique physical tasks.
  final int receivedBytes;

  /// Aggregate total bytes, or null while any task total is unknown.
  final int? totalBytes;

  /// Sum of currently measurable task speeds, in bytes per second.
  final double? bytesPerSecond;

  /// Unique physical task IDs in operation input order.
  final List<String> taskIds;

  /// Latest known update for each task ID.
  final Map<String, DownloadUpdate> taskUpdates;
}
