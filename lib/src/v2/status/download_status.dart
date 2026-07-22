/// Lifecycle states emitted by a V2 download task.
enum DownloadStatus {
  /// The task has been created but has not acquired a transfer slot.
  queued,

  /// The task is inspecting the server response and local staged state.
  preparing,

  /// One or more HTTP streams are writing file bytes.
  downloading,

  /// Network work has stopped while staged bytes remain available to resume.
  paused,

  /// The task is waiting to retry a transient failure.
  retrying,

  /// The final file was validated and moved into place.
  completed,

  /// The task stopped because of a non-recoverable error.
  failed,

  /// The caller intentionally stopped the task.
  cancelled,
}
