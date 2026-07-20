import 'package:dio/dio.dart';

import 'transfer_http_client.dart';
import 'transfer_cancellation.dart';
import 'transfer_response.dart';

/// Dio-backed streaming transport used by V2 transfers.
class DioTransferHttpClient implements TransferHttpClient {
  DioTransferHttpClient([Dio? dio]) : _dio = dio ?? Dio();

  final Dio _dio;

  @override
  Future<TransferResponse> get(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    TransferCancellation? cancellation,
  }) {
    return _open(url, method: 'GET', headers: headers, cancellation: cancellation);
  }

  @override
  Future<TransferResponse> head(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    TransferCancellation? cancellation,
  }) {
    return _open(url, method: 'HEAD', headers: headers, cancellation: cancellation);
  }

  Future<TransferResponse> _open(
    Uri url, {
    required String method,
    required Map<String, String> headers,
    required TransferCancellation? cancellation,
  }) async {
    final cancelToken = CancelToken();
    cancellation?.addListener(() => cancelToken.cancel('task cancelled'));
    final response = await _dio.requestUri<ResponseBody>(
      url,
      options: Options(
        method: method,
        headers: headers,
        responseType: ResponseType.stream,
        validateStatus: (_) => true,
      ),
      cancelToken: cancelToken,
    );
    final responseHeaders = <String, String>{
      for (final entry in response.headers.map.entries)
        entry.key: entry.value.join(','),
    };
    return TransferResponse(
      statusCode: response.statusCode ?? 0,
      headers: responseHeaders,
      body: response.data?.stream ?? const Stream<List<int>>.empty(),
    );
  }
}
