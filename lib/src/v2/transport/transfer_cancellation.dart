import 'dart:async';

/// A transport-neutral cancellation signal for one transfer task.
class TransferCancellation {
  final List<void Function()> _listeners = <void Function()>[];
  final Completer<void> _cancelled = Completer<void>();
  final Completer<void> _interrupted = Completer<void>();
  var _isCancelled = false;
  var _isPaused = false;

  bool get isCancelled => _isCancelled;
  bool get isPaused => _isPaused;
  Future<void> get whenCancelled => _cancelled.future;
  Future<void> get whenInterrupted => _interrupted.future;

  void addListener(void Function() listener) {
    if (_isCancelled || _isPaused) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  void cancel() {
    if (_isCancelled) {
      return;
    }
    _isCancelled = true;
    _cancelled.complete();
    _interrupt();
  }

  void pause() {
    if (_isCancelled || _isPaused) {
      return;
    }
    _isPaused = true;
    _interrupt();
  }

  void _interrupt() {
    if (!_interrupted.isCompleted) {
      _interrupted.complete();
    }
    for (final listener in List<void Function()>.from(_listeners)) {
      listener();
    }
    _listeners.clear();
  }
}
