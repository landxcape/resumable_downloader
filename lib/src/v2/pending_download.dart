/// Non-sensitive metadata for a durable transfer that can be restored.
class PendingDownload {
  /// Creates non-sensitive metadata describing a restorable transfer.
  const PendingDownload({
    required this.id,
    required this.sourceUri,
    required this.fileName,
    required this.totalBytes,
    this.restorationId,
    this.expectedSha256,
  });

  /// Stable identity of the persisted staging artifacts.
  final String id;

  /// Original source URL, retained for identification only.
  final Uri sourceUri;

  /// Final output file name.
  final String fileName;

  /// Expected size of the final file.
  final int totalBytes;

  /// App-owned key used to resolve a fresh authenticated request.
  final String? restorationId;

  /// Optional SHA-256 digest that the restored request must retain.
  final String? expectedSha256;
}
