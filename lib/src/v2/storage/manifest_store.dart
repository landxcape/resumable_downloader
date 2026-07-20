import 'dart:convert';
import 'dart:io';

import '../transfers/transfer_key.dart';
import 'transfer_manifest.dart';

/// Reads and writes V2 manifests in a directory isolated from legacy temp files.
class ManifestStore {
  ManifestStore(this._baseDirectory);

  final Directory _baseDirectory;

  Directory get _directory =>
      Directory('${_baseDirectory.path}/.resumable_downloader_v2');

  File _fileFor(TransferKey key) => File('${_directory.path}/${key.value}.json');

  Future<void> write(TransferManifest manifest) async {
    await _directory.create(recursive: true);
    final file = _fileFor(manifest.key);
    await file.writeAsString(jsonEncode(manifest.toJson()), flush: true);
  }

  Future<TransferManifest?> read(TransferKey key) async {
    final file = _fileFor(key);
    if (!await file.exists()) {
      return null;
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Invalid V2 transfer manifest JSON');
    }
    final manifest = TransferManifest.fromJson(decoded);
    if (manifest.key != key) {
      throw const FormatException('V2 transfer manifest key mismatch');
    }
    return manifest;
  }

  Future<void> delete(TransferKey key) async {
    final file = _fileFor(key);
    if (await file.exists()) {
      await file.delete();
    }
  }
}
