import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resumable_downloader/src/v2/storage/file_transfer_storage.dart';
import 'package:resumable_downloader/src/v2/storage/manifest_store.dart';
import 'package:resumable_downloader/src/v2/storage/transfer_manifest.dart';
import 'package:resumable_downloader/src/v2/transfers/byte_range.dart';
import 'package:resumable_downloader/src/v2/transfers/transfer_key.dart';

void main() {
  late Directory temporaryDirectory;
  late FileTransferStorage storage;
  late TransferKey key;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'rd-v2-storage-',
    );
    storage = FileTransferStorage(temporaryDirectory);
    key = TransferKey('fixture-key');
  });

  tearDown(() => temporaryDirectory.delete(recursive: true));

  test(
    'independent handles write non-overlapping ranges into one partial file',
    () async {
      final partial = await storage.createPartialFile(key, totalBytes: 6);

      await Future.wait([
        storage.writeRange(
          partial,
          const ByteRange(0, 2),
          Stream<List<int>>.value(<int>[0, 1, 2]),
        ),
        storage.writeRange(
          partial,
          const ByteRange(3, 5),
          Stream<List<int>>.value(<int>[3, 4, 5]),
        ),
      ]);

      expect(await partial.readAsBytes(), <int>[0, 1, 2, 3, 4, 5]);
    },
  );

  test('manifest store round trips a completed range map', () async {
    final store = ManifestStore(temporaryDirectory);
    final manifest = TransferManifest(
      key: key,
      sourceUri: Uri.parse('https://example.test/fixture.bin'),
      outputFileName: 'fixture.bin',
      totalBytes: 12,
      entityTag: '"fixture"',
      ranges: <TransferRangeCheckpoint>[
        TransferRangeCheckpoint(range: const ByteRange(0, 5), receivedBytes: 6),
      ],
    );

    await store.write(manifest);
    final restored = await store.read(key);

    expect(restored, manifest);
  });
}
