import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resumable_downloader/src/v2/download_request.dart';
import 'package:resumable_downloader/src/v2/storage/manifest_store.dart';
import 'package:resumable_downloader/src/v2/storage/transfer_manifest.dart';
import 'package:resumable_downloader/src/v2/transfers/byte_range.dart';
import 'package:resumable_downloader/src/v2/transfers/transfer_key.dart';

void main() {
  final request = DownloadRequest(
    url: Uri.parse('https://example.test/archive.bin?version=2'),
    fileName: 'archive.bin',
    subdirectory: 'downloads',
  );

  test('equivalent requests produce the same durable key', () {
    expect(
      TransferKey.fromRequest(request).value,
      matches(RegExp(r'^[a-f0-9]{64}$')),
    );
    expect(TransferKey.fromRequest(request), TransferKey.fromRequest(request));
  });

  test('manifest round trips request identity and range checkpoints', () {
    final manifest = TransferManifest(
      key: TransferKey.fromRequest(request),
      sourceUri: request.url,
      outputFileName: 'archive.bin',
      totalBytes: 64,
      ranges: <TransferRangeCheckpoint>[
        TransferRangeCheckpoint(range: ByteRange(0, 31), receivedBytes: 32),
        TransferRangeCheckpoint(range: ByteRange(32, 63), receivedBytes: 8),
      ],
    );

    expect(TransferManifest.fromJson(manifest.toJson()), manifest);
  });

  test('manifest rejects checkpoints beyond their range', () {
    expect(
      () => TransferRangeCheckpoint(range: ByteRange(0, 31), receivedBytes: 33),
      throwsArgumentError,
    );
  });

  test('serializes concurrent writes for the same manifest', () async {
    final directory = await Directory.systemTemp.createTemp('rd-v2-manifest-');
    addTearDown(() => directory.delete(recursive: true));
    final store = ManifestStore(directory);
    final key = TransferKey.fromRequest(request);

    await Future.wait(
      List<Future<void>>.generate(32, (index) {
        return store.write(
          TransferManifest(
            key: key,
            sourceUri: request.url,
            outputFileName: 'archive.bin',
            totalBytes: 64,
            ranges: <TransferRangeCheckpoint>[
              TransferRangeCheckpoint(
                range: ByteRange(0, 63),
                receivedBytes: index,
              ),
            ],
          ),
        );
      }),
    );

    expect((await store.read(key))!.ranges.single.receivedBytes, 31);
  });
}
