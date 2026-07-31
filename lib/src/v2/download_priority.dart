/// Scheduling importance for work waiting on shared transfer capacity.
enum DownloadPriority {
  /// Standard FIFO work.
  normal,

  /// Caller-declared foreground work scheduled before normal waiters.
  foreground,
}
