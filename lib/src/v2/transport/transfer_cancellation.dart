import 'dart:async';

/// A transport-neutral cancellation signal for one transfer task.
class TransferCancellation {
  final List<void Function()> _listeners = <void Function()>[];
  final Completer<void> _cancelled = Completer<void>();
  var _isCancelled = false;

  bool get isCancelled => _isCancelled;
  Future<void> get whenCancelled => _cancelled.future;

  void addListener(void Function() listener) {
    if (_isCancelled) {
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
    for (final listener in List<void Function()>.from(_listeners)) {
      listener();
    }
    _listeners.clear();
  }
}
