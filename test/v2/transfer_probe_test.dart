import 'package:flutter_test/flutter_test.dart';
import 'package:resumable_downloader/src/v2/transport/dio_transfer_http_client.dart';
import 'package:resumable_downloader/src/v2/transport/transfer_probe.dart';

import '../support/range_test_server.dart';

void main() {
  late RangeTestServer server;
  late TransferProbe probe;

  setUp(() async {
    server = await RangeTestServer.start(
      bytes: List<int>.generate(64, (index) => index),
    );
    probe = TransferProbe(DioTransferHttpClient());
  });

  tearDown(() => server.close());

  test('verifies a 206 response and content range', () async {
    final result = await probe.probe(server.uri);

    expect(result.totalBytes, 64);
    expect(result.supportsRanges, isTrue);
    expect(result.entityTag, '"fixture"');
  });

  test('marks a server that ignores range requests as single-stream only',
      () async {
    await server.close();
    server = await RangeTestServer.start(
      bytes: List<int>.generate(64, (index) => index),
      supportsRanges: false,
    );

    final result = await probe.probe(server.uri);

    expect(result.totalBytes, 64);
    expect(result.supportsRanges, isFalse);
  });

  test('does not accept a malformed content range', () async {
    await server.close();
    server = await RangeTestServer.start(
      bytes: List<int>.generate(64, (index) => index),
      malformedContentRange: true,
    );

    final result = await probe.probe(server.uri);

    expect(result.supportsRanges, isFalse);
  });

  test('keeps total bytes unknown when no response provides a length', () async {
    await server.close();
    server = await RangeTestServer.start(
      bytes: List<int>.generate(64, (index) => index),
      supportsRanges: false,
      includeContentLength: false,
    );

    final result = await probe.probe(server.uri);

    expect(result.totalBytes, isNull);
    expect(result.supportsRanges, isFalse);
  });
}
