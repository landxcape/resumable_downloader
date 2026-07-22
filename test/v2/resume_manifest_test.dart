import 'package:flutter_test/flutter_test.dart';
import 'package:resumable_downloader/src/v2/download_request.dart';
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
}
