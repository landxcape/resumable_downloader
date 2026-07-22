import 'dart:io';

import 'package:dio/dio.dart';

import 'download_exception.dart';

/// Decides whether a failed transfer attempt can reasonably succeed later.
class RetryPolicy {
  const RetryPolicy._();

  static bool shouldRetry(Object error) {
    if (error is DownloadCancelledException ||
        error is DownloadProtocolException) {
      return false;
    }
    if (error is DownloadHttpException) {
      return _isRetryableStatus(error.statusCode);
    }
    if (error is SocketException || error is HttpException) {
      return true;
    }
    if (error is DioException) {
      return switch (error.type) {
        DioExceptionType.cancel => false,
        DioExceptionType.badCertificate => false,
        DioExceptionType.badResponse => _isRetryableStatus(
          error.response?.statusCode,
        ),
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout ||
        DioExceptionType.transformTimeout ||
        DioExceptionType.connectionError ||
        DioExceptionType.unknown => true,
      };
    }
    return false;
  }

  static bool _isRetryableStatus(int? statusCode) {
    if (statusCode == null) {
      return false;
    }
    return statusCode == HttpStatus.requestTimeout ||
        statusCode == HttpStatus.tooManyRequests ||
        statusCode >= HttpStatus.internalServerError;
  }
}
