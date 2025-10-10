import 'dart:async';
import 'dart:io';

enum InternetStatus { connected, disconnected }

/// Android-box optimized implementation.
class NetworkInfo {
  NetworkInfo._();
  static final _instance = NetworkInfo._();
  static NetworkInfo get instance => _instance;

  // Cache to prevent repeated pings
  static bool? _lastPingResult;
  static DateTime? _lastPingTime;
  final Duration _cacheDuration = const Duration(seconds: 10);

  // Ping + HTTP timeout
  static const Duration _defaultTimeout = Duration(seconds: 1);

  // Controller for reactive updates
  final StreamController<InternetStatus> _controller =
      StreamController.broadcast();

  // Public stream
  Stream<InternetStatus> get internetStatus => _controller.stream;

  // Public connectivity getter
  Future<bool> get isConnected async {
    final hasInternet = await _hasUsableInternet(timeout: _defaultTimeout);
    return hasInternet;
  }

  /// Performs ping + fallback HTTP check
  Future<bool> _hasUsableInternet({Duration timeout = _defaultTimeout}) async {
    // Serve cached result if fresh
    if (_lastPingTime != null &&
        DateTime.now().difference(_lastPingTime!) < _cacheDuration) {
      return _lastPingResult ?? false;
    }

    final pingOk = await _pingGoogle(timeout: timeout);
    bool usable = pingOk;

    // If ping failed, try lightweight HTTP reachability
    if (!pingOk) {
      usable = await _checkHttpReachability(timeout: timeout);
    }

    // Cache result
    _lastPingResult = usable;
    _lastPingTime = DateTime.now();

    return usable;
  }

  /// Executes ICMP ping command (Android/Linux friendly)
  Future<bool> _pingGoogle({Duration timeout = _defaultTimeout}) async {
    try {
      final timeoutFlag = Platform.isWindows ? '-w' : '-W';
      final timeoutValue =
          Platform.isWindows
              ? timeout.inMilliseconds.toString()
              : timeout.inSeconds.toString();

      // Explicit path ensures consistency on Android box
      final result = await Process.run('/system/bin/ping', [
        '-c',
        '1',
        timeoutFlag,
        timeoutValue,
        '8.8.8.8',
      ]).timeout(timeout + const Duration(seconds: 1));

      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Fallback HTTP check — handles ICMP-blocked networks
  Future<bool> _checkHttpReachability({
    Duration timeout = _defaultTimeout,
  }) async {
    try {
      final client = HttpClient()..connectionTimeout = timeout;
      final request = await client.getUrl(
        Uri.parse('https://clients3.google.com/generate_204'),
      );
      final response = await request.close().timeout(timeout);
      return response.statusCode == 204;
    } catch (_) {
      return false;
    }
  }

  /// Dispose controller when done
  void dispose() {
    _controller.close();
  }
}
