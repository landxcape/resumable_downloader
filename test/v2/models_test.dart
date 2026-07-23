import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resumable_downloader/src/v2/download_configuration.dart';
import 'package:resumable_downloader/src/v2/download_request.dart';
import 'package:resumable_downloader/src/v2/download_validation.dart';
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
      final update = DownloadUpdate(
        taskId: 'task',
        status: DownloadStatus.downloading,
        receivedBytes: 12,
      );

      expect(update.progress, isNull);
    });

    test('calculates known progress', () {
      final update = DownloadUpdate(
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

  test('keeps an optional custom validator on the request', () {
    final file = File('fixture.bin');

    bool validator(DownloadValidationData data) => data.file.path == file.path;

    final request = DownloadRequest(
      url: Uri.parse('https://example.test/fixture.bin'),
      validator: validator,
    );

    expect(request.validator, same(validator));
  });
}
