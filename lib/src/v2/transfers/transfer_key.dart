import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../download_request.dart';

/// A filesystem-safe V2 identity used for partial data and manifests.
class TransferKey {
  factory TransferKey(String value) {
    if (!_validPattern.hasMatch(value)) {
      throw ArgumentError.value(value, 'value', 'must be filesystem-safe');
    }
    return TransferKey._(value);
  }

  const TransferKey._(this.value);

  factory TransferKey.fromRequest(DownloadRequest request) {
    final identity = jsonEncode(<String, String?>{
      'url': request.url.toString(),
      'fileName': request.fileName,
      'subdirectory': request.subdirectory,
      'restorationId': request.restorationId,
      'expectedSha256': request.expectedSha256,
    });
    return TransferKey(sha256.convert(utf8.encode(identity)).toString());
  }

  static final RegExp _validPattern = RegExp(r'^[A-Za-z0-9_-]+$');

  final String value;

  @override
  bool operator ==(Object other) =>
      other is TransferKey && other.value == value;

  @override
  int get hashCode => value.hashCode;
}
