import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../download_request.dart';
import '../pending_download.dart';
import '../transfers/byte_range.dart';
import '../transfers/transfer_key.dart';
import '../support/download_exception.dart';
import 'manifest_store.dart';
import 'transfer_manifest.dart';

/// Owns V2 partial files. Legacy `.tmp` files are never addressed here.
class FileTransferStorage {
  FileTransferStorage(this._baseDirectory);

  final Directory _baseDirectory;

  /// Finds durable V2 transfers below [rootDirectory].
  static Future<List<StoredPendingDownload>> discoverPending(
    Directory rootDirectory,
  ) async {
    if (!await rootDirectory.exists()) {
      return const <StoredPendingDownload>[];
    }
    final pending = <StoredPendingDownload>[];
    await for (final entity in rootDirectory.list(recursive: true)) {
      if (entity is! File ||
          entity.parent.path.split('/').last != '.resumable_downloader_v2') {
        continue;
      }
      if (!entity.path.endsWith('.json')) {
        continue;
      }
      final decoded = jsonDecode(await entity.readAsString());
      if (decoded is! Map<String, Object?>) {
        continue;
      }
      final manifest = TransferManifest.fromJson(decoded);
      pending.add(
        StoredPendingDownload(
          pending: PendingDownload(
            id: manifest.key.value,
            sourceUri: manifest.sourceUri,
            fileName: manifest.outputFileName,
            totalBytes: manifest.totalBytes,
            restorationId: manifest.restorationId,
            expectedSha256: manifest.expectedSha256,
          ),
          key: manifest.key,
          directory: entity.parent.parent,
        ),
      );
    }
    return pending;
  }

  late final ManifestStore _manifestStore = ManifestStore(_baseDirectory);

  Directory get _directory =>
      Directory('${_baseDirectory.path}/.resumable_downloader_v2');

  /// Opens durable partial storage without truncating existing transfer bytes.
  Future<File> openPartial(TransferKey key, {required int totalBytes}) async {
    if (totalBytes <= 0) {
      throw ArgumentError.value(totalBytes, 'totalBytes', 'must be positive');
    }
    await _directory.create(recursive: true);
    final file = File('${_directory.path}/${key.value}.partial');
    if (await file.exists()) {
      final existingLength = await file.length();
      if (existingLength != totalBytes) {
        throw StateError(
          'Partial file length $existingLength does not match $totalBytes',
        );
      }
      return file;
    }
    final handle = await file.open(mode: FileMode.write);
    try {
      await handle.setPosition(totalBytes - 1);
      await handle.writeByte(0);
    } finally {
      await handle.close();
    }
    return file;
  }

  /// @deprecated Use [openPartial] so existing partial bytes are preserved.
  Future<File> createPartialFile(TransferKey key, {required int totalBytes}) =>
      openPartial(key, totalBytes: totalBytes);

  Future<void> writeRange(
    File partial,
    ByteRange range,
    Stream<List<int>> source, {
    FutureOr<void> Function(int receivedBytes)? onProgress,
  }) async {
    final handle = await partial.open(mode: FileMode.append);
    var written = 0;
    try {
      await handle.setPosition(range.start);
      await for (final chunk in source) {
        written += chunk.length;
        if (written > range.length) {
          throw StateError('Range worker exceeded its assigned byte range');
        }
        await handle.writeFrom(chunk);
        await onProgress?.call(written);
      }
      if (written != range.length) {
        throw StateError(
          'Range worker did not complete its assigned byte range',
        );
      }
    } finally {
      await handle.close();
    }
  }

  Future<File> finalize(
    File partial, {
    required String fileName,
    required int expectedBytes,
  }) async {
    if (fileName.isEmpty || fileName.contains('/') || fileName.contains('\\')) {
      throw ArgumentError.value(fileName, 'fileName', 'must be a file name');
    }
    final output = File('${_baseDirectory.path}/$fileName');
    if (await output.exists()) {
      throw StateError('Output file already exists: ${output.path}');
    }
    final actualBytes = await partial.length();
    if (actualBytes != expectedBytes) {
      throw DownloadIntegrityException(
        'Partial file has $actualBytes bytes; expected $expectedBytes',
      );
    }
    return partial.rename(output.path);
  }

  Future<File?> resolveExistingOutput(
    String fileName,
    ExistingFilePolicy policy,
  ) async {
    _validateFileName(fileName);
    final output = File('${_baseDirectory.path}/$fileName');
    if (!await output.exists()) {
      return null;
    }
    switch (policy) {
      case ExistingFilePolicy.resume:
      case ExistingFilePolicy.keepExisting:
        return output;
      case ExistingFilePolicy.replace:
        await output.delete();
        return null;
      case ExistingFilePolicy.fail:
        throw StateError('Output file already exists: ${output.path}');
    }
  }

  Future<void> verifySha256(File partial, String expectedSha256) async {
    final actual = await sha256.bind(partial.openRead()).first;
    if (actual.toString() != expectedSha256) {
      throw const DownloadIntegrityException('SHA-256 verification failed');
    }
  }

  void _validateFileName(String fileName) {
    if (fileName.isEmpty || fileName.contains('/') || fileName.contains('\\')) {
      throw ArgumentError.value(fileName, 'fileName', 'must be a file name');
    }
  }

  Future<TransferManifest?> readManifest(TransferKey key) =>
      _manifestStore.read(key);

  Future<void> writeManifest(TransferManifest manifest) =>
      _manifestStore.write(manifest);

  Future<void> deleteManifest(TransferKey key) => _manifestStore.delete(key);

  Future<void> discard(TransferKey key) async {
    final partial = File('${_directory.path}/${key.value}.partial');
    if (await partial.exists()) {
      await partial.delete();
    }
    await _manifestStore.delete(key);
  }

  Future<void> deleteArtifacts(
    TransferKey key, {
    required String fileName,
    bool deleteOutput = true,
    bool deleteStaging = true,
  }) async {
    _validateFileName(fileName);
    if (deleteOutput) {
      final output = File('${_baseDirectory.path}/$fileName');
      if (await output.exists()) {
        await output.delete();
      }
    }
    if (deleteStaging) {
      await discard(key);
    }
  }
}

/// Internal location of a [PendingDownload] discovered on disk.
class StoredPendingDownload {
  const StoredPendingDownload({
    required this.pending,
    required this.key,
    required this.directory,
  });

  final PendingDownload pending;
  final TransferKey key;
  final Directory directory;
}
