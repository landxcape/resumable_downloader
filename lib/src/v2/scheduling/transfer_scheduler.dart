import 'dart:async';

import '../download_configuration.dart';
import 'connection_lease.dart';

/// Fairly allocates bounded HTTP connection slots to file transfers.
class TransferScheduler {
  TransferScheduler(this._configuration);

  final DownloadConfiguration _configuration;
  final Map<String, _TransferState> _transfers = <String, _TransferState>{};
  final List<_Waiter> _waiters = <_Waiter>[];
  var _activeConnections = 0;

  void enqueue(String transferId) {
    if (_transfers.containsKey(transferId)) {
      throw ArgumentError.value(transferId, 'transferId', 'already enqueued');
    }
    _transfers[transferId] = _TransferState();
  }

  Future<ConnectionLease> acquire(String transferId) {
    final state = _transfers[transferId];
    if (state == null) {
      return Future<ConnectionLease>.error(
        ArgumentError.value(transferId, 'transferId', 'is not enqueued'),
      );
    }
    final waiter = _Waiter(
      transferId: transferId,
      isPrimary: state.activeConnections == 0 && !state.hasStarted,
    );
    _waiters.add(waiter);
    _drain();
    return waiter.completer.future;
  }

  void complete(String transferId) {
    final state = _transfers[transferId];
    if (state == null) {
      return;
    }
    if (state.activeConnections != 0) {
      throw StateError('Cannot complete a transfer with active connections');
    }
    _transfers.remove(transferId);
    for (final waiter in _waiters.where(
      (item) => item.transferId == transferId,
    )) {
      waiter.completer.completeError(
        StateError('Transfer completed before its connection was granted'),
      );
    }
    _waiters.removeWhere((item) => item.transferId == transferId);
    _drain();
  }

  void _drain() {
    while (_activeConnections < _configuration.maxConcurrentConnections) {
      final waiter = _nextEligibleWaiter();
      if (waiter == null) {
        return;
      }
      _waiters.remove(waiter);
      final state = _transfers[waiter.transferId]!;
      state.activeConnections++;
      state.hasStarted = true;
      _activeConnections++;
      waiter.completer.complete(
        ConnectionLease(waiter.transferId, () => _release(waiter.transferId)),
      );
    }
  }

  _Waiter? _nextEligibleWaiter() {
    for (final primary in _waiters.where((waiter) => waiter.isPrimary)) {
      if (_canGrant(primary)) {
        return primary;
      }
    }
    for (final waiter in _waiters) {
      if (_canGrant(waiter)) {
        return waiter;
      }
    }
    return null;
  }

  bool _canGrant(_Waiter waiter) {
    final state = _transfers[waiter.transferId]!;
    if (state.activeConnections >= _configuration.maxConnectionsPerDownload) {
      return false;
    }
    if (state.activeConnections > 0) {
      return true;
    }
    return _activeTransferCount < _configuration.maxConcurrentDownloads;
  }

  int get _activeTransferCount =>
      _transfers.values.where((state) => state.activeConnections > 0).length;

  void _release(String transferId) {
    final state = _transfers[transferId];
    if (state == null || state.activeConnections == 0) {
      return;
    }
    state.activeConnections--;
    _activeConnections--;
    _drain();
  }
}

class _TransferState {
  var activeConnections = 0;
  var hasStarted = false;
}

class _Waiter {
  _Waiter({required this.transferId, required this.isPrimary});

  final String transferId;
  final bool isPrimary;
  final Completer<ConnectionLease> completer = Completer<ConnectionLease>();
}
