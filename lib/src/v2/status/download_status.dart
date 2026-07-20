/// Lifecycle states emitted by a V2 download task.
enum DownloadStatus {
  queued,
  preparing,
  downloading,
  retrying,
  completed,
  failed,
  cancelled,
}
