import 'dart:async';
import 'dart:io';

import 'status/download_update.dart';

/// A handle for one V2 transfer.
class DownloadTask {
  DownloadTask._(this.id)
      : _result = Completer<File>(),
        _updates = StreamController<DownloadUpdate>.broadcast(sync: true);

  final String id;
  final Completer<File> _result;
  final StreamController<DownloadUpdate> _updates;
  Future<void> Function()? _cancel;

  Stream<DownloadUpdate> get updates => _updates.stream;
  Future<File> get result => _result.future;

  Future<void> cancel() => _cancel?.call() ?? Future<void>.value();
}

/// Internal mutable side of a [DownloadTask].
class DownloadTaskController {
  DownloadTaskController(String id) : task = DownloadTask._(id);

  final DownloadTask task;

  void emit(DownloadUpdate update) {
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
