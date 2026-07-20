import 'package:flutter_test/flutter_test.dart';
import 'package:resumable_downloader/src/v2/download_configuration.dart';
import 'package:resumable_downloader/src/v2/scheduling/transfer_scheduler.dart';

void main() {
  test('scheduler gives a queued transfer its first lease before an extra lease',
      () async {
    final scheduler = TransferScheduler(
      DownloadConfiguration(
        maxConcurrentDownloads: 2,
        maxConcurrentConnections: 1,
        maxConnectionsPerDownload: 2,
      ),
    );
    scheduler.enqueue('large');
    scheduler.enqueue('small');

    final first = await scheduler.acquire('large');
    final extra = scheduler.acquire('large');
    final primary = scheduler.acquire('small');

    await first.release();
    final smallLease = await primary;

    expect(smallLease.transferId, 'small');
    await smallLease.release();
    await (await extra).release();
  });

  test('scheduler enforces the per-file connection limit', () async {
    final scheduler = TransferScheduler(
      DownloadConfiguration(
        maxConcurrentDownloads: 2,
        maxConcurrentConnections: 2,
        maxConnectionsPerDownload: 1,
      ),
    );
    scheduler.enqueue('a');
    scheduler.enqueue('b');

    final firstA = await scheduler.acquire('a');
    final secondA = scheduler.acquire('a');
    final firstB = await scheduler.acquire('b');

    expect(firstB.transferId, 'b');
    await firstA.release();
    await (await secondA).release();
    await firstB.release();
  });
}
