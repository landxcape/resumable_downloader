# resumable_downloader

`resumable_downloader` is a lightweight yet powerful download manager for Flutter. It supports:

✅ Resumable downloads using HTTP `Range` headers  
✅ Concurrent and queued download handling  
✅ File existence strategies (`keepExisting`, `resume`, `replace`, `fail`)  
✅ Download progress updates and cancelation support  
✅ Full control using `Dio`, custom directory setup, and retry handling  

Built for flexibility, designed for scalability.

## Features

- **Concurrent Downloading**  
  Support for downloading multiple files at once with efficient management of concurrent tasks.

- **Resumable Downloads**  
  Built-in support for resuming interrupted downloads, allowing downloads to continue from where they left off rather than starting over.

- **Download Progress Reporting**  
  Track and report download progress with real-time updates via a progress stream. The stream emits progress values between 0.0 (0%) and 1.0 (100%).

- **File Existence Handling**  
  Configurable strategies for handling existing files (e.g., skip, overwrite, or resume from the last known state).

- **Flexible Logging**  
  Optionally capture and log detailed information about each download, including errors and progress, with customizable log levels (e.g., info, warning, error).

- **Customizable Retry Logic**  
  Automatically retries failed downloads based on configurable retry parameters such as maximum retries and delay between attempts.

- **Cancel Downloads**  
  Easy cancellation of ongoing downloads, giving full control to the user.

- **Optional Callback for Progress**  
  Provides an optional callback function that allows users to track the download progress for each file in the queue.

- **Cross-Platform Support**  
  Works seamlessly across all platforms supported by Dart/Flutter, including mobile and desktop applications.

- **Optimized for Performance**  
  Efficiently handles multiple concurrent downloads while minimizing memory and CPU usage.

## Getting started

To get started with the `resumable_downloader` package, follow these steps:

### Prerequisites

1. Dart 2.12 or later is required. Ensure you have the latest version of Dart installed on your system.
2. Flutter (optional, but supported).
3. Internet access to download files.

### Installation

To install the package, add the following to your `pubspec.yaml` file:

```yaml
dependencies:
  resumable_downloader: <latest>
```

Then, run the following command in your project directory to fetch the package:

```dart
flutter pub get
```

## Usage

- Import the package in your Dart code:

```dart
import 'package:resumable_downloader/resumable_downloader.dart';
```

- Create an instance of DownloadManager:

```dart
final DownloadManager _downloadManager = DownloadManager(
    subDir: AppDefaults.downloadSubDir,
    fileExistsStrategy: FileExistsStrategy.resume, // optional
    baseDirectory: await getApplicationDocumentsDirectory(), // optional
    maxConcurrentDownloads: 3, // optional
    maxRetries: 3, // optional
    delayBetweenRetries: Duration.zero, // optional
    logger: (logRecord) { // optional
      logger.log(switch (logRecord.level) {
        LogLevel.debug => Level.debug,
        LogLevel.error => Level.error,
        LogLevel.warning => Level.warning,
        LogLevel.info => Level.info,
        // ignore: require_trailing_commas
      }, 'Download: ${logRecord.message}');
    },
  );
```

- Call the getFile, addToQueue, addAllToQueue method with the URL of the file you want to download and optional callbacks to handle progress and completion:

```dart
// Download immediately or enqueue with callback
_downloadManager.getFile(
  QueueItem(
    url: 'https://example.com/file.zip',
    fileName: 'download_file.zip', // optional
    progressCallback: (progressStream) {
      progressStream.listen((progress) {
        print('Download progress: ${(progress.progress * 100).toStringAsFixed(1)}%');
      });
    },
  ),
);

// Add one item to the queue
_downloadManager.addToQueue(
  QueueItem(
    url: 'https://example.com/another_file.zip',
    fileName: 'download_another_file.zip', // optional
    progressCallback: (progressStream) {
      progressStream.listen((progress) {
        print('Queued file progress: ${(progress.progress * 100).toStringAsFixed(1)}%');
      });
    },
  ),
);

// Add multiple items to the queue
_downloadManager.addAllToQueue([
  QueueItem(
    url: 'https://example.com/file1.zip',
    fileName: 'download_file1.zip', // optional
    progressCallback: (stream) {
      stream.listen((progress) {
        print('File 1 progress: ${(progress.progress * 100).toStringAsFixed(1)}%');
      });
    },
  ),
  QueueItem(
    url: 'https://example.com/file2.zip',
    fileName: 'download_file2.zip', // optional
    progressCallback: (stream) {
      stream.listen((progress) {
        print('File 2 progress: ${(progress.progress * 100).toStringAsFixed(1)}%');
      });
    },
  ),
]);
```

- Make sure to dispose it

```dart
_downloadManager.dispose();
```

## Additional information

This is a straightforward, practical guide for users to get started with the package.

### Troubleshooting

- Ensure the download URL is valid and supports Range headers.
- Progress won’t emit unless the server provides a valid Content-Length.
- Check logs for any errors using your provided logger.
