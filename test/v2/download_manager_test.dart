import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resumable_downloader/resumable_downloader.dart';
import 'package:resumable_downloader/src/v2/storage/file_transfer_storage.dart';
import 'package:resumable_downloader/src/v2/storage/transfer_manifest.dart';
import 'package:resumable_downloader/src/v2/transfers/byte_range.dart';
import 'package:resumable_downloader/src/v2/transfers/transfer_key.dart';

import '../support/range_test_server.dart';

void main() {
  test(
    'root manager enqueues a task and forwards manager-wide updates',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'rd-v2-manager-',
      );
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
    },
  );

  test('manager caps probe and transfer requests across files', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'rd-v2-manager-limit-',
    );
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

  test('manager forwards task cancellation to the active transfer', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'rd-v2-manager-cancel-',
    );
    final server = await RangeTestServer.start(
      bytes: List<int>.generate(32, (index) => index),
      responseDelay: const Duration(milliseconds: 100),
    );
    addTearDown(server.close);
    addTearDown(() => temporaryDirectory.delete(recursive: true));

    final manager = DownloadManager(baseDirectory: temporaryDirectory);
    final task = manager.enqueue(
      DownloadRequest(url: server.uri, fileName: 'cancelled.bin'),
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));
    await task.cancel();

    await expectLater(task.result, throwsA(isA<DownloadCancelledException>()));
    await manager.dispose();
  });

  test('manager forwards pause and resume to the active transfer', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'rd-v2-manager-pause-',
    );
    final server = await RangeTestServer.start(
      bytes: List<int>.generate(512, (index) => index % 256),
      chunkSize: 8,
      chunkDelay: const Duration(milliseconds: 20),
    );
    addTearDown(server.close);
    addTearDown(() => temporaryDirectory.delete(recursive: true));

    final manager = DownloadManager(
      baseDirectory: temporaryDirectory,
      configuration: DownloadConfiguration(
        checkpointBytes: 8,
        maxConcurrentConnections: 1,
        maxConnectionsPerDownload: 2,
        minimumBytesPerPart: 256,
        maxRetries: 0,
      ),
    );
    final task = manager.enqueue(
      DownloadRequest(url: server.uri, fileName: 'paused.bin'),
    );
    final paused = task.updates.firstWhere(
      (update) => update.status == DownloadStatus.paused,
    );

    await task.updates.firstWhere((update) => update.receivedBytes >= 8);
    await task.pause();
    expect((await paused).receivedBytes, greaterThanOrEqualTo(8));

    await task.resume();
    expect(await task.result, isA<File>());
    await manager.dispose();
  });

  test('manager reuses an active task for the same durable request', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'rd-v2-manager-duplicate-',
    );
    final server = await RangeTestServer.start(
      bytes: List<int>.generate(32, (index) => index),
      responseDelay: const Duration(milliseconds: 50),
    );
    addTearDown(server.close);
    addTearDown(() => temporaryDirectory.delete(recursive: true));

    final manager = DownloadManager(baseDirectory: temporaryDirectory);
    final request = DownloadRequest(url: server.uri, fileName: 'same.bin');

    final first = manager.enqueue(request);
    final second = manager.enqueue(request);

    expect(identical(first, second), isTrue);
    await first.result;
    await manager.dispose();
  });

  test('manager deletes completed output and resumable artifacts', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'rd-v2-manager-delete-',
    );
    final server = await RangeTestServer.start(
      bytes: List<int>.generate(32, (index) => index),
    );
    addTearDown(server.close);
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final manager = DownloadManager(baseDirectory: temporaryDirectory);
    final request = DownloadRequest(url: server.uri, fileName: 'delete.bin');

    await manager.download(request);
    await manager.deleteArtifacts(request);

    expect(
      await File('${temporaryDirectory.path}/delete.bin').exists(),
      isFalse,
    );
    await manager.dispose();
  });

  test('manager can cancel and delete active transfer artifacts', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'rd-v2-manager-delete-active-',
    );
    final server = await RangeTestServer.start(
      bytes: List<int>.generate(512, (index) => index),
      chunkSize: 8,
      chunkDelay: const Duration(milliseconds: 20),
    );
    addTearDown(server.close);
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final manager = DownloadManager(baseDirectory: temporaryDirectory);
    final request = DownloadRequest(url: server.uri, fileName: 'active.bin');
    final task = manager.enqueue(request);
    final result = expectLater(
      task.result,
      throwsA(isA<DownloadCancelledException>()),
    );

    await task.updates.firstWhere((update) => update.receivedBytes > 0);
    await manager.deleteArtifacts(request, cancelActive: true);

    await result;
    expect(
      await File('${temporaryDirectory.path}/active.bin').exists(),
      isFalse,
    );
    await manager.dispose();
  });

  test(
    'manager restores a pending transfer through a fresh request resolver',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'rd-v2-manager-restore-',
      );
      final bytes = List<int>.generate(4096, (index) => index % 256);
      final initialServer = await RangeTestServer.start(
        bytes: bytes,
        chunkSize: 8,
        chunkDelay: const Duration(milliseconds: 20),
      );
      addTearDown(initialServer.close);
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      final configuration = DownloadConfiguration(
        checkpointBytes: 8,
        maxConcurrentConnections: 1,
        maxConnectionsPerDownload: 2,
        minimumBytesPerPart: 2048,
        maxRetries: 0,
      );
      final request = DownloadRequest(
        url: initialServer.uri,
        fileName: 'restored.bin',
        restorationId: 'invoice-8421',
        headers: const <String, String>{
          'Authorization': 'Bearer initial-secret',
        },
      );
      final initialManager = DownloadManager(
        baseDirectory: temporaryDirectory,
        configuration: configuration,
      );
      final initialTask = initialManager.enqueue(request);
      final cancelled = expectLater(
        initialTask.result,
        throwsA(isA<DownloadCancelledException>()),
      );
      await initialTask.updates.firstWhere(
        (update) => update.receivedBytes >= 8,
      );
      await initialTask.cancel();
      await cancelled;
      await initialManager.dispose();

      final manifestFiles =
          await Directory(temporaryDirectory.path)
              .list(recursive: true)
              .where(
                (entity) => entity is File && entity.path.endsWith('.json'),
              )
              .cast<File>()
              .toList();
      final manifest = await manifestFiles.single.readAsString();
      expect(manifest, isNot(contains('initial-secret')));

      final refreshedServer = await RangeTestServer.start(
        bytes: bytes,
        entityTag: '"changed"',
      );
      addTearDown(refreshedServer.close);
      final restoredManager = DownloadManager(
        baseDirectory: temporaryDirectory,
        configuration: configuration,
      );
      final pending = await restoredManager.pendingDownloads();
      expect(pending.single.restorationId, 'invoice-8421');
      expect(pending.single.sourceUri, initialServer.uri);

      final tasks = await restoredManager.restorePending((pending) async {
        return DownloadRequest(
          url: refreshedServer.uri,
          fileName: pending.fileName,
          restorationId: pending.restorationId,
          headers: const <String, String>{
            'Authorization': 'Bearer fresh-token',
          },
        );
      });

      expect(await tasks.single.result, isA<File>());
      expect(
        await File('${temporaryDirectory.path}/restored.bin').readAsBytes(),
        bytes,
      );
      expect(refreshedServer.requestedRanges, contains('bytes=0-2047'));
      await restoredManager.dispose();
    },
  );

  test('manager restores pending transfers within scheduler limits', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'rd-v2-manager-batch-restore-',
    );
    final bytes = List<int>.generate(64, (index) => index);
    final server = await RangeTestServer.start(
      bytes: bytes,
      responseDelay: const Duration(milliseconds: 30),
    );
    addTearDown(server.close);
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final storage = FileTransferStorage(temporaryDirectory);
    final requests = <DownloadRequest>[
      DownloadRequest(
        url: server.uri,
        fileName: 'first.bin',
        restorationId: 'first',
      ),
      DownloadRequest(
        url: server.uri,
        fileName: 'second.bin',
        restorationId: 'second',
      ),
    ];
    for (final request in requests) {
      final key = TransferKey.fromRequest(request);
      await storage.openPartial(key, totalBytes: bytes.length);
      await storage.writeManifest(
        TransferManifest(
          key: key,
          sourceUri: request.url,
          outputFileName: request.fileName!,
          totalBytes: bytes.length,
          restorationId: request.restorationId,
          ranges: <TransferRangeCheckpoint>[
            TransferRangeCheckpoint(
              range: ByteRange(0, bytes.length - 1),
              receivedBytes: 0,
            ),
          ],
        ),
      );
    }
    final manager = DownloadManager(
      baseDirectory: temporaryDirectory,
      configuration: DownloadConfiguration(
        maxConcurrentDownloads: 1,
        maxConcurrentConnections: 1,
        maxConnectionsPerDownload: 1,
      ),
    );

    final tasks = await manager.restorePending((pending) async {
      return requests.singleWhere(
        (request) => request.restorationId == pending.restorationId,
      );
    });

    await Future.wait(tasks.map((task) => task.result));
    expect(server.maxConcurrentRequests, 1);
    await manager.dispose();
  });
}
