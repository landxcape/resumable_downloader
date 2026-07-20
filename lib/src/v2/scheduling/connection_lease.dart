/// A single global connection slot granted by [TransferScheduler].
class ConnectionLease {
  ConnectionLease(this.transferId, this._onRelease);

  final String transferId;
  final void Function() _onRelease;
  var _released = false;

  Future<void> release() async {
    if (_released) {
      return;
    }
    _released = true;
    _onRelease();
  }
}
