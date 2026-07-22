import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resumable_downloader/src/v2/support/retry_policy.dart';

void main() {
  test('retries a Dio transformation timeout', () {
    final error = DioException(
      requestOptions: RequestOptions(path: 'https://example.com/file.bin'),
      type: DioExceptionType.transformTimeout,
    );

    expect(RetryPolicy.shouldRetry(error), isTrue);
  });
}
