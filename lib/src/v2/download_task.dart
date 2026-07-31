import 'dart:async';
import 'dart:io';

import 'status/download_update.dart';

/// A handle for one V2 transfer.
class DownloadTask {
  DownloadTask._(this.id)
    : _result = Completer<File>(),
      _updates = StreamController<DownloadUpdate>.broadcast(sync: true);

  /// Manager-scoped identifier for this task.
  final String id;
  final Completer<File> _result;
  final StreamController<DownloadUpdate> _updates;
  DownloadUpdate? _latestUpdate;
  Future<void> Function()? _cancel;
  Future<void> Function()? _pause;
  Future<void> Function()? _resume;

  /// Ordered lifecycle and progress snapshots for this task.
  Stream<DownloadUpdate> get updates => _updates.stream;

  /// Most recent lifecycle snapshot, or `null` before the first emission.
  DownloadUpdate? get latestUpdate => _latestUpdate;

  /// Completes with the finalized file or fails with a typed download exception.
  Future<File> get result => _result.future;

  /// Whether [result] has completed successfully or with an error.
  bool get isCompleted => _result.isCompleted;

  /// Stops the transfer and removes its resumable artifacts.
  Future<void> cancel() => _cancel?.call() ?? Future<void>.value();

  /// Stops active network work while retaining the partial transfer state.
  Future<void> pause() => _pause?.call() ?? Future<void>.value();

  /// Continues a transfer previously paused through [pause].
  Future<void> resume() => _resume?.call() ?? Future<void>.value();
}

/// Internal mutable side of a [DownloadTask].
class DownloadTaskController {
  DownloadTaskController(String id) : task = DownloadTask._(id);

  final DownloadTask task;

  void setCancelHandler(Future<void> Function() handler) {
    task._cancel = handler;
  }

  void setPauseHandler(Future<void> Function() handler) {
    task._pause = handler;
  }

  void setResumeHandler(Future<void> Function() handler) {
    task._resume = handler;
  }

  DownloadUpdate? get lastUpdate => task._latestUpdate;

  void emit(DownloadUpdate update) {
    task._latestUpdate = update;
    if (!task._updates.isClosed) {
      task._updates.add(update);
    }
  }

  void complete(File file) {
    if (!task._result.isCompleted) {
      task._result.complete(file);
    }
    unawaited(task._updates.close());
  }

  void fail(Object error, StackTrace stackTrace) {
    if (!task._result.isCompleted) {
      task._result.completeError(error, stackTrace);
    }
    unawaited(task._updates.close());
  }
}
