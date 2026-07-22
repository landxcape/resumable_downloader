import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

class RangeTestServer {
  RangeTestServer._(
    this._server,
    this._bytes, {
    required this.supportsRanges,
    required this.malformedContentRange,
    required this.includeContentLength,
    required this.responseDelay,
    required this.failFirstRequests,
    required this.failingRequestNumbers,
    required this.forcedStatusCode,
    required this.entityTag,
    required this.chunkSize,
    required this.chunkDelay,
  });

  final HttpServer _server;
  final List<int> _bytes;
  final bool supportsRanges;
  final bool malformedContentRange;
  final bool includeContentLength;
  final Duration responseDelay;
  final int failFirstRequests;
  final Set<int> failingRequestNumbers;
  final int? forcedStatusCode;
  String entityTag;
  final int? chunkSize;
  final Duration chunkDelay;
  var _activeRequests = 0;
  var _requestCount = 0;
  var maxConcurrentRequests = 0;
  final List<String> requestedRanges = <String>[];

  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}/fixture.bin');

  static Future<RangeTestServer> start({
    required List<int> bytes,
    bool supportsRanges = true,
    bool malformedContentRange = false,
    bool includeContentLength = true,
    Duration responseDelay = Duration.zero,
    int failFirstRequests = 0,
    Set<int> failingRequestNumbers = const <int>{},
    int? forcedStatusCode,
    String entityTag = '"fixture"',
    int? chunkSize,
    Duration chunkDelay = Duration.zero,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final result = RangeTestServer._(
      server,
      List<int>.unmodifiable(bytes),
      supportsRanges: supportsRanges,
      malformedContentRange: malformedContentRange,
      includeContentLength: includeContentLength,
      responseDelay: responseDelay,
      failFirstRequests: failFirstRequests,
      failingRequestNumbers: Set<int>.unmodifiable(failingRequestNumbers),
      forcedStatusCode: forcedStatusCode,
      entityTag: entityTag,
      chunkSize: chunkSize,
      chunkDelay: chunkDelay,
    );
    server.listen((request) => unawaited(result._handle(request)));
    return result;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    _requestCount++;
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    if (rangeHeader != null) {
      requestedRanges.add(rangeHeader);
    }
    _activeRequests++;
    maxConcurrentRequests =
        maxConcurrentRequests < _activeRequests
            ? _activeRequests
            : maxConcurrentRequests;
    try {
      if (forcedStatusCode != null) {
        request.response.statusCode = forcedStatusCode!;
        await request.response.close();
        return;
      }
      if (_requestCount <= failFirstRequests ||
          failingRequestNumbers.contains(_requestCount)) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
        return;
      }
      if (responseDelay > Duration.zero) {
        await Future<void>.delayed(responseDelay);
      }
      final response = request.response;
      if (chunkSize != null) {
        response.bufferOutput = false;
      }
      response.headers.set(HttpHeaders.etagHeader, entityTag);
      if (includeContentLength && request.method == 'HEAD') {
        response.contentLength = _bytes.length;
      }
      if (request.method == 'HEAD') {
        await response.close();
        return;
      }

      final match = RegExp(
        r'^bytes=(\d+)-(\d+)$',
      ).firstMatch(rangeHeader ?? '');
      if (supportsRanges && match != null) {
        final start = int.parse(match.group(1)!);
        final end = int.parse(match.group(2)!);
        final slice = _bytes.sublist(start, end + 1);
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          malformedContentRange
              ? 'bytes $start-${end + 1}/${_bytes.length}'
              : 'bytes $start-$end/${_bytes.length}',
        );
        if (includeContentLength) {
          response.contentLength = slice.length;
        }
        await _writeBytes(response, slice);
        await response.close();
        return;
      }

      if (includeContentLength) {
        response.contentLength = _bytes.length;
      }
      await _writeBytes(response, _bytes);
      await response.close();
    } finally {
      _activeRequests--;
    }
  }

  Future<void> _writeBytes(HttpResponse response, List<int> bytes) async {
    final size = chunkSize;
    if (size == null) {
      response.add(Uint8List.fromList(bytes));
      return;
    }
    for (var offset = 0; offset < bytes.length; offset += size) {
      response.add(
        Uint8List.fromList(
          bytes.sublist(offset, (offset + size).clamp(0, bytes.length)),
        ),
      );
      await response.flush();
      if (chunkDelay > Duration.zero) {
        await Future<void>.delayed(chunkDelay);
      }
    }
  }
}
