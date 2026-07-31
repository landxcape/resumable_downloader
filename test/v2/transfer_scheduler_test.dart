import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:resumable_downloader/src/v2/download_configuration.dart';
import 'package:resumable_downloader/src/v2/download_priority.dart';
import 'package:resumable_downloader/src/v2/scheduling/transfer_scheduler.dart';

void main() {
  test('foreground primary waiter precedes normal pending work', () async {
    final scheduler = TransferScheduler(
      DownloadConfiguration(
        maxConcurrentDownloads: 1,
        maxConcurrentConnections: 1,
        maxConnectionsPerDownload: 1,
      ),
    );
    scheduler.enqueue('active');
    scheduler.enqueue('normal');
    scheduler.enqueue('foreground', priority: DownloadPriority.foreground);

    final active = await scheduler.acquire('active');
    final normal = scheduler.acquire('normal');
    final foreground = scheduler.acquire('foreground');

    await active.release();
    final foregroundLease = await foreground;
    expect(foregroundLease.transferId, 'foreground');
    await foregroundLease.release();
    final normalLease = await normal;
    expect(normalLease.transferId, 'normal');
    await normalLease.release();
  });

  test('promotion reorders one pending task without duplicating it', () async {
    final scheduler = TransferScheduler(
      DownloadConfiguration(
        maxConcurrentDownloads: 1,
        maxConcurrentConnections: 1,
        maxConnectionsPerDownload: 1,
      ),
    );
    scheduler.enqueue('active');
    scheduler.enqueue('c');
    scheduler.enqueue('b');

    final active = await scheduler.acquire('active');
    final b = scheduler.acquire('b');
    final c = scheduler.acquire('c');
    var cCompleted = false;
    unawaited(c.then((_) => cCompleted = true));
    scheduler.promote('b', DownloadPriority.foreground);
    scheduler.promote('b', DownloadPriority.foreground);

    await active.release();
    final bLease = await b;
    expect(bLease.transferId, 'b');
    expect(cCompleted, isFalse);
    await bLease.release();
    await (await c).release();
  });

  test('normal promotion cannot downgrade foreground work', () async {
    final scheduler = TransferScheduler(
      DownloadConfiguration(
        maxConcurrentDownloads: 1,
        maxConcurrentConnections: 1,
        maxConnectionsPerDownload: 1,
      ),
    );
    scheduler.enqueue('active');
    scheduler.enqueue('c');
    scheduler.enqueue('b');

    final active = await scheduler.acquire('active');
    final b = scheduler.acquire('b');
    final c = scheduler.acquire('c');
    scheduler.promote('b', DownloadPriority.foreground);
    scheduler.promote('b', DownloadPriority.normal);

    await active.release();
    final bLease = await b;
    expect(bLease.transferId, 'b');
    await bLease.release();
    await (await c).release();
  });

  test('promotion never revokes an already granted lease', () async {
    final scheduler = TransferScheduler(
      DownloadConfiguration(
        maxConcurrentDownloads: 1,
        maxConcurrentConnections: 1,
        maxConnectionsPerDownload: 1,
      ),
    );
    scheduler.enqueue('a');
    scheduler.enqueue('b');

    final aLease = await scheduler.acquire('a');
    final b = scheduler.acquire('b');
    var bCompleted = false;
    unawaited(b.then((_) => bCompleted = true));
    scheduler.promote('b', DownloadPriority.foreground);

    expect(aLease.transferId, 'a');
    expect(bCompleted, isFalse);
    await aLease.release();
    expect((await b).transferId, 'b');
    await (await b).release();
  });

  test(
    'scheduler gives a queued transfer its first lease before an extra lease',
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
    },
  );

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
