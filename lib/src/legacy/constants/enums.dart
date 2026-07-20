// --- Enums and Typedefs ---

enum LogLevel {
  /// Verbose logging, useful for deep debugging.
  debug,

  /// Logging for recoverable errors or unexpected conditions.
  error,

  /// Logging for potential issues or non-critical problems.
  warning,

  /// General informational messages about the manager's state or actions.
  info,
}

/// Defines the strategy to employ when a file with the target name
/// already exists at the download location during a download request.
enum FileExistsStrategy {
  /// Replaces the existing file. The download starts from the beginning,
  /// overwriting any existing file with the same name. This also applies if a `.tmp` file exists.
  replace,

  /// Keeps the existing *final* file and skips the download. The operation completes
  /// successfully, returning the existing [File] object. No network request is made.
  /// If only a `.tmp` file exists, the download proceeds.
  keepExisting,

  /// Fails the download operation immediately if the *final* file exists.
  /// Throws a [FileSystemException]. If only a `.tmp` file exists, the download proceeds.
  ///
  /// Use this if you need strict guarantees that existing data must not be overwritten or resumed —
  /// typically in secure or one-time download scenarios.
  ///
  /// 🚫 Not recommended for most use cases. Prefer [replace] or [resume].
  fail,

  /// Resumes the download if a partial file (`.tmp`) exists. If the final file
  /// already exists completely, behaves like [keepExisting]. If neither exists,
  /// starts a new download. This relies on the server supporting range requests.
  resume,
}
