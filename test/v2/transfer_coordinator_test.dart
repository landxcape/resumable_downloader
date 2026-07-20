import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resumable_downloader/src/v2/download_request.dart';
import 'package:resumable_downloader/src/v2/storage/file_transfer_storage.dart';
import 'package:resumable_downloader/src/v2/status/download_status.dart';
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

  test('single stream emits terminal updates and atomically returns the file',
      () async {
    final task = coordinator.start(
      DownloadRequest(url: server.uri, fileName: 'fixture.bin'),
    );
    final updates = task.updates.toList();

    final file = await task.result;

    expect(await file.readAsBytes(), fixtureBytes);
    expect(
      (await updates).map((update) => update.status),
      containsAllInOrder([
        DownloadStatus.preparing,
        DownloadStatus.downloading,
        DownloadStatus.completed,
      ]),
    );
    expect(await File('${temporaryDirectory.path}/fixture.bin').exists(), isTrue);
  });
}
