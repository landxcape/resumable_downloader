import 'dart:io';

import '../transfers/byte_range.dart';
import '../transfers/transfer_key.dart';

/// Owns V2 partial files. Legacy `.tmp` files are never addressed here.
class FileTransferStorage {
  FileTransferStorage(this._baseDirectory);

  final Directory _baseDirectory;

  Directory get _directory =>
      Directory('${_baseDirectory.path}/.resumable_downloader_v2');

  Future<File> createPartialFile(
    TransferKey key, {
    required int totalBytes,
  }) async {
    if (totalBytes <= 0) {
      throw ArgumentError.value(totalBytes, 'totalBytes', 'must be positive');
    }
    await _directory.create(recursive: true);
    final file = File('${_directory.path}/${key.value}.partial');
    final handle = await file.open(mode: FileMode.write);
    try {
      await handle.setPosition(totalBytes - 1);
      await handle.writeByte(0);
    } finally {
      await handle.close();
    }
    return file;
  }

  Future<void> writeRange(
    File partial,
    ByteRange range,
    Stream<List<int>> source,
  ) async {
    final handle = await partial.open(mode: FileMode.writeOnly);
    var written = 0;
    try {
      await handle.setPosition(range.start);
      await for (final chunk in source) {
        written += chunk.length;
        if (written > range.length) {
          throw StateError('Range worker exceeded its assigned byte range');
        }
        await handle.writeFrom(chunk);
      }
      if (written != range.length) {
        throw StateError('Range worker did not complete its assigned byte range');
      }
    } finally {
      await handle.close();
    }
  }

  Future<File> finalize(File partial, {required String fileName}) async {
    if (fileName.isEmpty || fileName.contains('/') || fileName.contains('\\')) {
      throw ArgumentError.value(fileName, 'fileName', 'must be a file name');
    }
    final output = File('${_baseDirectory.path}/$fileName');
    if (await output.exists()) {
      throw StateError('Output file already exists: ${output.path}');
    }
    return partial.rename(output.path);
  }
}
