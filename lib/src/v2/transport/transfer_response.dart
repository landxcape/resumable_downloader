import 'dart:async';

/// A streamed HTTP response with normalized, case-insensitive header keys.
class TransferResponse {
  TransferResponse({
    required this.statusCode,
    required Map<String, String> headers,
    required this.body,
  }) : headers = Map.unmodifiable({
         for (final entry in headers.entries)
           entry.key.toLowerCase(): entry.value,
       });

  final int statusCode;
  final Map<String, String> headers;
  final Stream<List<int>> body;

  String? header(String name) => headers[name.toLowerCase()];
}
