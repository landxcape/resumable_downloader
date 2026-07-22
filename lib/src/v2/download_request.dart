/// Defines how an existing output file is handled before a V2 transfer starts.
enum ExistingFilePolicy {
  /// Reuse a matching staged transfer or an existing completed output.
  resume,

  /// Remove an existing completed output before starting a new transfer.
  replace,

  /// Reuse an existing completed output without inspecting staged data.
  keepExisting,

  /// Fail when the output file already exists.
  fail,
}

/// Immutable input for one V2 download task.
class DownloadRequest {
  /// Creates immutable input for a single download task.
  DownloadRequest({
    required this.url,
    this.fileName,
    this.subdirectory,
    this.restorationId,
    Map<String, String> headers = const <String, String>{},
    this.existingFilePolicy = ExistingFilePolicy.resume,
    String? expectedSha256,
  }) : headers = Map.unmodifiable(headers),
       expectedSha256 = _normalizeSha256(expectedSha256);

  /// Source URL for the transfer.
  final Uri url;

  /// Destination file name, or the source URL's last path segment when null.
  final String? fileName;

  /// One destination-directory segment below the manager's directory.
  final String? subdirectory;

  /// Stable app-owned identifier used to resolve fresh authenticated requests.
  final String? restorationId;

  /// Headers applied to probe and transfer requests; never persisted to disk.
  final Map<String, String> headers;

  /// Behavior when the final output already exists.
  final ExistingFilePolicy existingFilePolicy;

  /// Optional lowercase SHA-256 digest required before finalization.
  final String? expectedSha256;

  static String? _normalizeSha256(String? value) {
    if (value == null) {
      return null;
    }
    final normalized = value.toLowerCase();
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(normalized)) {
      throw ArgumentError.value(
        value,
        'expectedSha256',
        'must be a 64-character hexadecimal SHA-256 digest',
      );
    }
    return normalized;
  }
}
