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
  });

  final HttpServer _server;
  final List<int> _bytes;
  final bool supportsRanges;
  final bool malformedContentRange;
  final bool includeContentLength;
  final Duration responseDelay;
  var _activeRequests = 0;
  var maxConcurrentRequests = 0;

  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}/fixture.bin');

  static Future<RangeTestServer> start({
    required List<int> bytes,
    bool supportsRanges = true,
    bool malformedContentRange = false,
    bool includeContentLength = true,
    Duration responseDelay = Duration.zero,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final result = RangeTestServer._(
      server,
      List<int>.unmodifiable(bytes),
      supportsRanges: supportsRanges,
      malformedContentRange: malformedContentRange,
      includeContentLength: includeContentLength,
      responseDelay: responseDelay,
    );
    server.listen((request) => unawaited(result._handle(request)));
    return result;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    _activeRequests++;
    maxConcurrentRequests = maxConcurrentRequests < _activeRequests
        ? _activeRequests
        : maxConcurrentRequests;
    try {
      if (responseDelay > Duration.zero) {
        await Future<void>.delayed(responseDelay);
      }
      final response = request.response;
      response.headers.set(HttpHeaders.etagHeader, '"fixture"');
      if (includeContentLength && request.method == 'HEAD') {
        response.contentLength = _bytes.length;
      }
      if (request.method == 'HEAD') {
        await response.close();
        return;
      }

      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      final match =
          RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(rangeHeader ?? '');
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
        response.add(Uint8List.fromList(slice));
        await response.close();
        return;
      }

      if (includeContentLength) {
        response.contentLength = _bytes.length;
      }
      response.add(Uint8List.fromList(_bytes));
      await response.close();
    } finally {
      _activeRequests--;
    }
  }
}
