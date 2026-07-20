import 'package:flutter_test/flutter_test.dart';
import 'package:resumable_downloader/src/v2/download_configuration.dart';
import 'package:resumable_downloader/src/v2/download_request.dart';
import 'package:resumable_downloader/src/v2/status/download_status.dart';
import 'package:resumable_downloader/src/v2/status/download_update.dart';

void main() {
  group('DownloadConfiguration', () {
    test('rejects non-positive connection limits', () {
      expect(
        () => DownloadConfiguration(maxConcurrentDownloads: 0),
        throwsArgumentError,
      );
      expect(
        () => DownloadConfiguration(maxConcurrentConnections: 0),
        throwsArgumentError,
      );
      expect(
        () => DownloadConfiguration(maxConnectionsPerDownload: 0),
        throwsArgumentError,
      );
    });
  });

  group('DownloadUpdate', () {
    test('reports unknown progress as null', () {
      const update = DownloadUpdate(
        taskId: 'task',
        status: DownloadStatus.downloading,
        receivedBytes: 12,
      );

      expect(update.progress, isNull);
    });

    test('calculates known progress', () {
      const update = DownloadUpdate(
        taskId: 'task',
        status: DownloadStatus.downloading,
        receivedBytes: 12,
        totalBytes: 48,
      );

      expect(update.progress, 0.25);
    });
  });

  test('request defaults to resuming an existing partial file', () {
    final request = DownloadRequest(
      url: Uri.parse('https://example.test/file.bin'),
    );

    expect(request.existingFilePolicy, ExistingFilePolicy.resume);
    expect(request.headers, isEmpty);
  });
}
