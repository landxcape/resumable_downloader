import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resumable_downloader/resumable_downloader.dart';

import '../support/range_test_server.dart';

void main() {
  test('root manager enqueues a task and forwards manager-wide updates', () async {
    final temporaryDirectory =
        await Directory.systemTemp.createTemp('rd-v2-manager-');
    final server = await RangeTestServer.start(
      bytes: List<int>.generate(32, (index) => index),
    );
    addTearDown(server.close);
    addTearDown(() => temporaryDirectory.delete(recursive: true));

    final manager = DownloadManager(baseDirectory: temporaryDirectory);
    final completed = manager.updates.firstWhere(
      (update) => update.status == DownloadStatus.completed,
    );
    final task = manager.enqueue(
      DownloadRequest(url: server.uri, fileName: 'fixture.bin'),
    );

    expect(await task.result, isA<File>());
    expect((await completed).outputPath, endsWith('fixture.bin'));
    await manager.dispose();
  });

  test('manager caps probe and transfer requests across files', () async {
    final temporaryDirectory =
        await Directory.systemTemp.createTemp('rd-v2-manager-limit-');
    final server = await RangeTestServer.start(
      bytes: List<int>.generate(32, (index) => index),
      responseDelay: const Duration(milliseconds: 30),
    );
    addTearDown(server.close);
    addTearDown(() => temporaryDirectory.delete(recursive: true));

    final manager = DownloadManager(
      baseDirectory: temporaryDirectory,
      configuration: DownloadConfiguration(
        maxConcurrentDownloads: 1,
        maxConcurrentConnections: 1,
        maxConnectionsPerDownload: 1,
      ),
    );

    final first = manager.enqueue(
      DownloadRequest(url: server.uri, fileName: 'first.bin'),
    );
    final second = manager.enqueue(
      DownloadRequest(url: server.uri, fileName: 'second.bin'),
    );

    await Future.wait(<Future<File>>[first.result, second.result]);

    expect(server.maxConcurrentRequests, 1);
    await manager.dispose();
  });
}
