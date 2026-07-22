import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resumable_downloader/src/v2/download_request.dart';
import 'package:resumable_downloader/src/v2/scheduling/transfer_scheduler.dart';
import 'package:resumable_downloader/src/v2/download_configuration.dart';
import 'package:resumable_downloader/src/v2/support/download_exception.dart';
import 'package:resumable_downloader/src/v2/storage/file_transfer_storage.dart';
import 'package:resumable_downloader/src/v2/transfers/transfer_key.dart';
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

  test('resuming a request returns an existing completed output', () async {
    final request = DownloadRequest(url: server.uri, fileName: 'existing.bin');

    final first = await coordinator.start(request).result;
    final resumed = await coordinator.start(request).result;

    expect(resumed.path, first.path);
    expect(await resumed.readAsBytes(), fixtureBytes);
  });

  test('replace policy downloads over an existing completed output', () async {
    await coordinator
        .start(DownloadRequest(url: server.uri, fileName: 'replace.bin'))
        .result;

    final replaced =
        await coordinator
            .start(
              DownloadRequest(
                url: server.uri,
                fileName: 'replace.bin',
                existingFilePolicy: ExistingFilePolicy.replace,
              ),
            )
            .result;

    expect(await replaced.readAsBytes(), fixtureBytes);
  });

  test('discards a corrupted manifest and restarts cleanly', () async {
    final request = DownloadRequest(url: server.uri, fileName: 'corrupt.bin');
    final key = TransferKey.fromRequest(request);
    final manifest = File(
      '${temporaryDirectory.path}/.resumable_downloader_v2/${key.value}.json',
    );
    await manifest.parent.create(recursive: true);
    await manifest.writeAsString('{not json');

    final output = await coordinator.start(request).result;

    expect(await output.readAsBytes(), fixtureBytes);
  });

  test('discards a truncated partial file and restarts cleanly', () async {
    final request = DownloadRequest(url: server.uri, fileName: 'truncated.bin');
    final key = TransferKey.fromRequest(request);
    final partial = await FileTransferStorage(
      temporaryDirectory,
    ).openPartial(key, totalBytes: fixtureBytes.length);
    await partial.writeAsBytes(<int>[1]);

    final output = await coordinator.start(request).result;

    expect(await output.readAsBytes(), fixtureBytes);
  });

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

  test('a later task resumes an incomplete range from its checkpoint', () async {
    await server.close();
    fixtureBytes = List<int>.generate(4096, (index) => index % 256);
    server = await RangeTestServer.start(
      bytes: fixtureBytes,
      chunkSize: 8,
      chunkDelay: const Duration(milliseconds: 20),
    );
    final configuration = DownloadConfiguration(
      checkpointBytes: 8,
      maxConcurrentConnections: 1,
      maxConnectionsPerDownload: 2,
      minimumBytesPerPart: 2048,
      maxRetries: 0,
    );
    final client = DioTransferHttpClient();
    coordinator = TransferCoordinator(
      storage: FileTransferStorage(temporaryDirectory),
      transport: client,
      probe: TransferProbe(client),
      configuration: configuration,
    );
    final request = DownloadRequest(url: server.uri, fileName: 'partial.bin');
    final task = coordinator.start(request);
    final result = expectLater(
      task.result,
      throwsA(isA<DownloadCancelledException>()),
    );

    await task.updates.firstWhere((update) => update.receivedBytes >= 8);
    await task.cancel();
    await result;

    final manifest = await FileTransferStorage(
      temporaryDirectory,
    ).readManifest(TransferKey.fromRequest(request));
    final checkpoint = manifest!.ranges.firstWhere(
      (range) => range.receivedBytes > 0 && !range.isComplete,
    );
    expect(checkpoint.receivedBytes, greaterThanOrEqualTo(8));
    expect(checkpoint.receivedBytes, lessThan(checkpoint.range.length));

    final output = await coordinator.start(request).result;

    expect(await output.readAsBytes(), fixtureBytes);
    expect(
      server.requestedRanges,
      contains(
        'bytes=${checkpoint.range.start + checkpoint.receivedBytes}-${checkpoint.range.end}',
      ),
    );
  });

  test('pausing and resuming keeps the same task pending', () async {
    await server.close();
    fixtureBytes = List<int>.generate(4096, (index) => index % 256);
    server = await RangeTestServer.start(
      bytes: fixtureBytes,
      chunkSize: 8,
      chunkDelay: const Duration(milliseconds: 20),
    );
    final client = DioTransferHttpClient();
    coordinator = TransferCoordinator(
      storage: FileTransferStorage(temporaryDirectory),
      transport: client,
      probe: TransferProbe(client),
      configuration: DownloadConfiguration(
        checkpointBytes: 8,
        maxConcurrentConnections: 1,
        maxConnectionsPerDownload: 2,
        minimumBytesPerPart: 2048,
        maxRetries: 0,
      ),
    );
    final task = coordinator.start(
      DownloadRequest(url: server.uri, fileName: 'paused.bin'),
    );
    var completed = false;
    task.result.then((_) => completed = true);

    await task.updates.firstWhere((update) => update.receivedBytes >= 8);
    await task.pause();
    await task.updates.firstWhere(
      (update) => update.status == DownloadStatus.paused,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(completed, isFalse);

    await task.resume();
    final file = await task.result;

    expect(await file.readAsBytes(), fixtureBytes);
  });

  test('retries a transient probe failure before completing', () async {
    await server.close();
    server = await RangeTestServer.start(
      bytes: fixtureBytes,
      failFirstRequests: 1,
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

  test('does not retry a permanent HTTP failure', () async {
    await server.close();
    server = await RangeTestServer.start(
      bytes: fixtureBytes,
      forcedStatusCode: HttpStatus.notFound,
    );
    final client = DioTransferHttpClient();
    coordinator = TransferCoordinator(
      storage: FileTransferStorage(temporaryDirectory),
      transport: client,
      probe: TransferProbe(client),
      configuration: DownloadConfiguration(
        maxRetries: 3,
        retryDelay: Duration.zero,
      ),
    );
    final task = coordinator.start(
      DownloadRequest(url: server.uri, fileName: 'missing.bin'),
    );
    final updates = task.updates.toList();

    await expectLater(task.result, throwsA(isA<DownloadHttpException>()));
    expect(
      (await updates).map((update) => update.status),
      isNot(contains(DownloadStatus.retrying)),
    );
  });

  test('rejects a completed file whose SHA-256 does not match', () async {
    final request = DownloadRequest(
      url: server.uri,
      fileName: 'checksum.bin',
      expectedSha256:
          '0000000000000000000000000000000000000000000000000000000000000000',
    );
    final task = coordinator.start(request);

    await expectLater(task.result, throwsA(isA<DownloadIntegrityException>()));
    expect(
      await File('${temporaryDirectory.path}/checksum.bin').exists(),
      isFalse,
    );
    expect(
      await FileTransferStorage(
        temporaryDirectory,
      ).readManifest(TransferKey.fromRequest(request)),
      isNull,
    );
  });

  test('finalizes a completed file with a matching SHA-256', () async {
    final task = coordinator.start(
      DownloadRequest(
        url: server.uri,
        fileName: 'verified.bin',
        expectedSha256: sha256.convert(fixtureBytes).toString(),
      ),
    );

    final file = await task.result;

    expect(await file.readAsBytes(), fixtureBytes);
  });

  test('does not retry a malformed range probe response', () async {
    await server.close();
    server = await RangeTestServer.start(
      bytes: fixtureBytes,
      malformedContentRange: true,
    );
    final client = DioTransferHttpClient();
    coordinator = TransferCoordinator(
      storage: FileTransferStorage(temporaryDirectory),
      transport: client,
      probe: TransferProbe(client),
      configuration: DownloadConfiguration(
        maxRetries: 3,
        retryDelay: Duration.zero,
      ),
    );
    final task = coordinator.start(
      DownloadRequest(url: server.uri, fileName: 'malformed.bin'),
    );
    final updates = task.updates.toList();

    await expectLater(task.result, throwsA(isA<DownloadProtocolException>()));
    expect(
      (await updates).map((update) => update.status),
      isNot(contains(DownloadStatus.retrying)),
    );
  });

  test(
    'falls back to a single stream when the range probe is ignored',
    () async {
      await server.close();
      server = await RangeTestServer.start(
        bytes: fixtureBytes,
        supportsRanges: false,
      );
      final task = coordinator.start(
        DownloadRequest(url: server.uri, fileName: 'single-stream.bin'),
      );

      final file = await task.result;

      expect(await file.readAsBytes(), fixtureBytes);
    },
  );

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
