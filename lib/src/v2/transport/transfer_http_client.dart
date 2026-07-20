import 'transfer_response.dart';
import 'transfer_cancellation.dart';

/// HTTP operations required by V2 probes and range workers.
abstract interface class TransferHttpClient {
  Future<TransferResponse> head(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    TransferCancellation? cancellation,
  });

  Future<TransferResponse> get(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    TransferCancellation? cancellation,
  });
}
