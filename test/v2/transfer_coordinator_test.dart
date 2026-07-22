import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resumable_downloader/src/v2/download_request.dart';
import 'package:resumable_downloader/src/v2/scheduling/transfer_scheduler.dart';
import 'package:resumable_downloader/src/v2/download_configuration.dart';
import 'package:resumable_downloader/src/v2/support/download_exception.dart';
import 'package:resumable_downloader/src/v2/storage/file_transfer_storage.dart';
import 'package:resumable_downloader/src/v2/status/download_status.dart';
import 'package:resumable_downloader/src/v2/status/download_update.dart';
import 'package:resumable_downloader/src/v2/transport/dio_transfer_http_client.dart';
import 'package:resumable_downloader/src/v2/transport/transfer_probe.dart';
import 'package:resumable_downloader/src/v2/transfers/transfer_coordinator.dart';

import '../support/range_test_server.dart';

void main() {
  late Directory temporaryDirectory;
  late RangeTestServer server;
  late TransferCoordinator coordinator;
  late List<int> fixtureBytes;

  setUp(() async {
    fixtureBytes = List<int>.generate(64, (index) => index);
    temporaryDirectory = await Directory.systemTemp.createTemp('rd-v2-task-');
    server = await RangeTestServer.start(bytes: fixtureBytes);
    final client = DioTransferHttpClient();
    coordinator = TransferCoordinator(
      storage: FileTransferStorage(temporaryDirectory),
      transport: client,
      probe: TransferProbe(client),
    );
  });

  tearDown(() async {
    await server.close();
    await temporaryDirectory.delete(recursive: true);
  });

  test(
    'single stream emits terminal updates and atomically returns the file',
    () async {
      final task = coordinator.start(
        DownloadRequest(url: server.uri, fileName: 'fixture.bin'),
      );
      final updates = task.updates.toList();

      final file = await task.result;

      expect(await file.readAsBytes(), fixtureBytes);
      expect((await updates).last.ranges, hasLength(1));
      expect(
        (await updates).map((update) => update.status),
        containsAllInOrder([
          DownloadStatus.preparing,
          DownloadStatus.downloading,
          DownloadStatus.completed,
        ]),
      );
      expect(
        await File('${temporaryDirectory.path}/fixture.bin').exists(),
        isTrue,
      );
    },
  );

  test('cancelling a task reaches a cancelled terminal state', () async {
    await server.close();
    server = await RangeTestServer.start(
      bytes: fixtureBytes,
      responseDelay: const Duration(milliseconds: 100),
    );
    final task = coordinator.start(
      DownloadRequest(url: server.uri, fileName: 'cancelled.bin'),
    );
    final updates = task.updates.toList();

    await Future<void>.delayed(const Duration(milliseconds: 10));
    await task.cancel();

    await expectLater(task.result, throwsA(isA<DownloadCancelledException>()));
    expect((await updates).last.status, DownloadStatus.cancelled);
  });

  test('retries a transient probe failure before completing', () async {
    await server.close();
    server = await RangeTestServer.start(
      bytes: fixtureBytes,
      failFirstRequests: 2,
    );
    final client = DioTransferHttpClient();
    coordinator = TransferCoordinator(
      storage: FileTransferStorage(temporaryDirectory),
      transport: client,
      probe: TransferProbe(client),
      configuration: DownloadConfiguration(
        maxRetries: 1,
        retryDelay: Duration.zero,
      ),
    );
    final task = coordinator.start(
      DownloadRequest(url: server.uri, fileName: 'retried.bin'),
    );
    final updates = task.updates.toList();

    final file = await task.result;

    expect(await file.readAsBytes(), fixtureBytes);
    expect(
      (await updates).map((update) => update.status),
      contains(DownloadStatus.retrying),
    );
    expect(
      (await updates).where(
        (update) => update.status == DownloadStatus.retrying,
      ),
      everyElement(
        predicate((DownloadUpdate update) => update.retryAttempt == 1),
      ),
    );
  });

  test('retries a multipart range failure before completing', () async {
    await server.close();
    server = await RangeTestServer.start(
      bytes: fixtureBytes,
      failingRequestNumbers: <int>{3},
    );
    final client = DioTransferHttpClient();
    coordinator = TransferCoordinator(
      storage: FileTransferStorage(temporaryDirectory),
      transport: client,
      probe: TransferProbe(client),
      configuration: DownloadConfiguration(
        maxConcurrentDownloads: 1,
        maxConcurrentConnections: 4,
        maxConnectionsPerDownload: 4,
        minimumBytesPerPart: 8,
        maxRetries: 1,
        retryDelay: Duration.zero,
      ),
    );
    final task = coordinator.start(
      DownloadRequest(url: server.uri, fileName: 'retried-multipart.bin'),
    );
    final updates = task.updates.toList();

    final file = await task.result;

    expect(await file.readAsBytes(), fixtureBytes);
    expect(
      (await updates).map((update) => update.status),
      contains(DownloadStatus.retrying),
    );
  });

  test('cancelling during retry backoff does not wait for the delay', () async {
    await server.close();
    server = await RangeTestServer.start(
      bytes: fixtureBytes,
      failFirstRequests: 10,
    );
    final client = DioTransferHttpClient();
    coordinator = TransferCoordinator(
      storage: FileTransferStorage(temporaryDirectory),
      transport: client,
      probe: TransferProbe(client),
      configuration: DownloadConfiguration(
        maxRetries: 3,
        retryDelay: const Duration(seconds: 1),
      ),
    );
    final task = coordinator.start(
      DownloadRequest(url: server.uri, fileName: 'cancel-retry.bin'),
    );
    final result = expectLater(
      task.result,
      throwsA(isA<DownloadCancelledException>()),
    );

    await task.updates.firstWhere(
      (update) => update.status == DownloadStatus.retrying,
    );
    final stopwatch = Stopwatch()..start();
    await task.cancel();

    await result;
    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 250)));
  });

  test(
    'a later task skips completed ranges from a failed multipart task',
    () async {
      await server.close();
      server = await RangeTestServer.start(
        bytes: fixtureBytes,
        failingRequestNumbers: <int>{4},
      );
      final configuration = DownloadConfiguration(
        maxConcurrentDownloads: 1,
        maxConcurrentConnections: 1,
        maxConnectionsPerDownload: 2,
        minimumBytesPerPart: 32,
        maxRetries: 0,
      );
      final client = DioTransferHttpClient();
      coordinator = TransferCoordinator(
        storage: FileTransferStorage(temporaryDirectory),
        transport: client,
        probe: TransferProbe(client),
        configuration: configuration,
        scheduler: TransferScheduler(configuration),
      );
      final request = DownloadRequest(url: server.uri, fileName: 'resume.bin');
      final failed = coordinator.start(request);
      final failedResult = expectLater(failed.result, throwsA(anything));

      await failedResult;
      final output = await coordinator.start(request).result;

      expect(await output.readAsBytes(), fixtureBytes);
      expect(
        server.requestedRanges.where((range) => range == 'bytes=0-31'),
        hasLength(1),
      );
      expect(
        server.requestedRanges.where((range) => range == 'bytes=32-63'),
        hasLength(2),
      );
    },
  );

  test('a changed entity tag discards stale completed ranges', () async {
    await server.close();
    server = await RangeTestServer.start(
      bytes: fixtureBytes,
      failingRequestNumbers: <int>{4},
    );
    final configuration = DownloadConfiguration(
      maxConcurrentDownloads: 1,
      maxConcurrentConnections: 1,
      maxConnectionsPerDownload: 2,
      minimumBytesPerPart: 32,
      maxRetries: 0,
    );
    final client = DioTransferHttpClient();
    coordinator = TransferCoordinator(
      storage: FileTransferStorage(temporaryDirectory),
      transport: client,
      probe: TransferProbe(client),
      configuration: configuration,
      scheduler: TransferScheduler(configuration),
    );
    final request = DownloadRequest(url: server.uri, fileName: 'etag.bin');
    final failed = coordinator.start(request);

    await expectLater(failed.result, throwsA(anything));
    server.entityTag = '"changed"';

    final output = await coordinator.start(request).result;

    expect(await output.readAsBytes(), fixtureBytes);
    expect(
      server.requestedRanges.where((range) => range == 'bytes=0-31'),
      hasLength(2),
    );
  });
}
