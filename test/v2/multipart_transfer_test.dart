import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resumable_downloader/src/v2/download_configuration.dart';
import 'package:resumable_downloader/src/v2/download_request.dart';
import 'package:resumable_downloader/src/v2/scheduling/transfer_scheduler.dart';
import 'package:resumable_downloader/src/v2/storage/file_transfer_storage.dart';
import 'package:resumable_downloader/src/v2/transport/dio_transfer_http_client.dart';
import 'package:resumable_downloader/src/v2/transport/transfer_probe.dart';
import 'package:resumable_downloader/src/v2/transfers/transfer_coordinator.dart';

import '../support/range_test_server.dart';

void main() {
  test('eligible files assemble four verified ranges', () async {
    final bytes = List<int>.generate(64, (index) => index);
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'rd-v2-multipart-',
    );
    final server = await RangeTestServer.start(bytes: bytes);
    addTearDown(server.close);
    addTearDown(() => temporaryDirectory.delete(recursive: true));

    final configuration = DownloadConfiguration(
      maxConcurrentDownloads: 1,
      maxConcurrentConnections: 4,
      maxConnectionsPerDownload: 4,
      minimumBytesPerPart: 8,
    );
    final client = DioTransferHttpClient();
    final coordinator = TransferCoordinator(
      storage: FileTransferStorage(temporaryDirectory),
      transport: client,
      probe: TransferProbe(client),
      configuration: configuration,
      scheduler: TransferScheduler(configuration),
    );

    final task = coordinator.start(
      DownloadRequest(url: server.uri, fileName: 'fixture.bin'),
    );
    final updates = task.updates.toList();

    final file = await task.result;
    final completed = (await updates).last;

    expect(await file.readAsBytes(), bytes);
    expect(completed.completedRanges, 4);
    expect(completed.ranges, hasLength(4));
    expect(completed.ranges.map((range) => range.progress), everyElement(1.0));
  });
}
