import 'dart:async';
import 'dart:io';

/// Validates a completed V2 download before V2 returns or finalizes it.
///
/// Return `true` to accept [data.file] and `false` to reject it. Treat the
/// file as read-only; V2 owns its lifecycle.
typedef DownloadValidator =
    FutureOr<bool> Function(DownloadValidationData data);

/// Immutable metadata supplied to a [DownloadValidator].
final class DownloadValidationData {
  /// Creates data for one completed staged or retained output file.
  const DownloadValidationData({
    required this.file,
    required this.sourceUri,
    required this.fileName,
    required this.totalBytes,
  });

  /// Completed staged file or retained final output; do not modify it.
  final File file;

  /// URL associated with the request being validated.
  final Uri sourceUri;

  /// Resolved output file name without directory segments.
  final String fileName;

  /// Number of bytes in [file] at validation time.
  final int totalBytes;
}
