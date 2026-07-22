import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resumable_downloader/resumable_downloader.dart';
import 'package:resumable_downloader/src/v2/storage/file_transfer_storage.dart';
import 'package:resumable_downloader/src/v2/transfers/transfer_key.dart';

void main() {
  test('does not finalize a partial file with an unexpected length', () async {
    final directory = await Directory.systemTemp.createTemp('rd-v2-storage-');
    addTearDown(() => directory.delete(recursive: true));
    final storage = FileTransferStorage(directory);
    final partial = await storage.openPartial(
      TransferKey('fixture'),
      totalBytes: 8,
    );
    await partial.writeAsBytes(<int>[1, 2, 3, 4], flush: true);

    await expectLater(
      storage.finalize(partial, fileName: 'fixture.bin', expectedBytes: 8),
      throwsA(isA<DownloadIntegrityException>()),
    );
    expect(await File('${directory.path}/fixture.bin').exists(), isFalse);
  });
}
