/// A transport-neutral cancellation signal for one transfer task.
class TransferCancellation {
  final List<void Function()> _listeners = <void Function()>[];
  var _isCancelled = false;

  bool get isCancelled => _isCancelled;

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
    for (final listener in List<void Function()>.from(_listeners)) {
      listener();
    }
    _listeners.clear();
  }
}
