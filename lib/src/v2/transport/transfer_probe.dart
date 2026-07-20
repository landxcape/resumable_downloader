import 'transfer_http_client.dart';

/// Metadata verified before selecting a V2 transfer plan.
class TransferProbeResult {
  const TransferProbeResult({
    required this.totalBytes,
    required this.supportsRanges,
    this.entityTag,
    this.lastModified,
  });

  final int? totalBytes;
  final bool supportsRanges;
  final String? entityTag;
  final String? lastModified;
}

/// Probes a server instead of trusting `Accept-Ranges` alone.
class TransferProbe {
  TransferProbe(this._client);

  final TransferHttpClient _client;

  Future<TransferProbeResult> probe(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
  }) async {
    final head = await _client.head(url, headers: headers);
    await head.body.drain<void>();

    final headLength = _parsePositiveInt(head.header('content-length'));
    final entityTag = head.header('etag');
    final lastModified = head.header('last-modified');
    final rangeResponse = await _client.get(
      url,
      headers: <String, String>{...headers, 'Range': 'bytes=0-0'},
    );
    await rangeResponse.body.drain<void>();

    final range = _parseContentRange(rangeResponse.header('content-range'));
    final supportsRanges = rangeResponse.statusCode == 206 &&
        range != null &&
        range.start == 0 &&
        range.end == 0;
    final totalBytes = supportsRanges
        ? range.total
        : headLength ?? _parsePositiveInt(rangeResponse.header('content-length'));

    return TransferProbeResult(
      totalBytes: totalBytes,
      supportsRanges: supportsRanges,
      entityTag: entityTag ?? rangeResponse.header('etag'),
      lastModified: lastModified ?? rangeResponse.header('last-modified'),
    );
  }

  int? _parsePositiveInt(String? value) {
    final result = int.tryParse(value ?? '');
    return result != null && result > 0 ? result : null;
  }

  _ContentRange? _parseContentRange(String? value) {
    final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(value ?? '');
    if (match == null) {
      return null;
    }
    final start = int.parse(match.group(1)!);
    final end = int.parse(match.group(2)!);
    final total = int.parse(match.group(3)!);
    if (total <= 0 || start > end || end >= total) {
      return null;
    }
    return _ContentRange(start, end, total);
  }
}

class _ContentRange {
  const _ContentRange(this.start, this.end, this.total);

  final int start;
  final int end;
  final int total;
}
