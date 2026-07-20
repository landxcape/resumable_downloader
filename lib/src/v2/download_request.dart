/// Defines how an existing output file is handled before a V2 transfer starts.
enum ExistingFilePolicy { resume, replace, keepExisting, fail }

/// Immutable input for one V2 download task.
class DownloadRequest {
  DownloadRequest({
    required this.url,
    this.fileName,
    this.subdirectory,
    Map<String, String> headers = const <String, String>{},
    this.existingFilePolicy = ExistingFilePolicy.resume,
  }) : headers = Map.unmodifiable(headers);

  final Uri url;
  final String? fileName;
  final String? subdirectory;
  final Map<String, String> headers;
  final ExistingFilePolicy existingFilePolicy;
}
