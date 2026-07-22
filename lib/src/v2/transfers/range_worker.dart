import 'dart:io';
import 'dart:async';

import '../scheduling/transfer_scheduler.dart';
import '../storage/file_transfer_storage.dart';
import '../transport/transfer_http_client.dart';
import '../transport/transfer_cancellation.dart';
import 'byte_range.dart';

/// Downloads and validates one assigned HTTP byte range.
class RangeWorker {
  RangeWorker({
    required TransferScheduler scheduler,
    required TransferHttpClient transport,
    required FileTransferStorage storage,
  }) : _scheduler = scheduler,
       _transport = transport,
       _storage = storage;

  final TransferScheduler _scheduler;
  final TransferHttpClient _transport;
  final FileTransferStorage _storage;

  Future<void> run({
    required String transferId,
    required Uri url,
    required File partial,
    required ByteRange range,
    required int totalBytes,
    Map<String, String> headers = const <String, String>{},
    TransferCancellation? cancellation,
    void Function(int receivedBytes)? onProgress,
    FutureOr<void> Function()? onComplete,
  }) async {
    final lease = await _scheduler.acquire(transferId);
    try {
      final response = await _transport.get(
        url,
        headers: <String, String>{
          ...headers,
          'Range': 'bytes=${range.start}-${range.end}',
        },
        cancellation: cancellation,
      );
      if (response.statusCode != HttpStatus.partialContent ||
          !_matchesRange(response.header('content-range'), range, totalBytes)) {
        throw HttpException('Server did not honor the requested byte range');
      }
      await _storage.writeRange(
        partial,
        range,
        response.body,
        onProgress: onProgress,
      );
      await onComplete?.call();
    } finally {
      await lease.release();
    }
  }

  bool _matchesRange(String? value, ByteRange range, int totalBytes) {
    return value == 'bytes ${range.start}-${range.end}/$totalBytes';
  }
}
