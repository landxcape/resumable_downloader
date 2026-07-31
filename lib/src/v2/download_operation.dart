import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'download_task.dart';
import 'status/download_update.dart';

/// Creates an operation for tasks already accepted by a download manager.
///
/// This is an internal package factory and is not exported from the package
/// entrypoint.
DownloadOperation createDownloadOperation({
  required String id,
  required List<DownloadTask> tasks,
}) {
  return DownloadOperation._(id: id, tasks: tasks);
}

/// A hot logical scope over one or more download tasks.
///
/// Creating an operation starts its tasks. Listening to [updates] only observes
/// those tasks and never starts or repeats transfer work.
class DownloadOperation {
  DownloadOperation._({required this.id, required List<DownloadTask> tasks})
    : tasks = List<DownloadTask>.unmodifiable(tasks),
      _result = Future.wait<File>(tasks.map((task) => task.result)) {
    _uniqueTasks = _identityUnique(tasks);
    _bindUniqueTasks();
  }

  /// Manager-scoped identifier for this operation.
  final String id;

  /// Tasks in the same order as the operation's input requests.
  ///
  /// Equivalent inputs can occupy multiple positions while sharing one task.
  final List<DownloadTask> tasks;

  final Future<List<File>> _result;
  final StreamController<DownloadUpdate> _live =
      StreamController<DownloadUpdate>.broadcast(sync: true);
  final Map<DownloadTask, DownloadUpdate> _latest =
      <DownloadTask, DownloadUpdate>{};
  final List<StreamSubscription<DownloadUpdate>> _subscriptions =
      <StreamSubscription<DownloadUpdate>>[];
  late final List<DownloadTask> _uniqueTasks;
  var _remainingUniqueTasks = 0;

  /// Completes with files in the same order as [tasks].
  Future<List<File>> get result => _result;

  /// Whether every unique task has reached a terminal result.
  bool get isCompleted => tasks.every((task) => task.isCompleted);

  /// Current snapshots followed by live updates from only this operation.
  ///
  /// Each listener observes the current state independently. Re-listening does
  /// not enqueue or restart any task.
  Stream<DownloadUpdate> get updates => _watchUpdates();

  void _bindUniqueTasks() {
    _remainingUniqueTasks = _uniqueTasks.length;
    if (_remainingUniqueTasks == 0) {
      unawaited(_live.close());
      return;
    }

    for (final task in _uniqueTasks) {
      final latest = task.latestUpdate;
      if (latest != null) {
        _latest[task] = latest;
      }
      _subscriptions.add(
        task.updates.listen(
          (update) {
            _latest[task] = update;
            if (!_live.isClosed) {
              _live.add(update);
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!_live.isClosed) {
              _live.addError(error, stackTrace);
            }
          },
          onDone: _taskCompleted,
        ),
      );
    }
  }

  void _taskCompleted() {
    _remainingUniqueTasks--;
    if (_remainingUniqueTasks == 0 && !_live.isClosed) {
      unawaited(_live.close());
    }
  }

  Stream<DownloadUpdate> _watchUpdates() async* {
    final buffered = StreamController<DownloadUpdate>();
    final subscription = _live.stream.listen(
      buffered.add,
      onError: buffered.addError,
      onDone: buffered.close,
    );
    final snapshots = <DownloadUpdate>[
      for (final task in _uniqueTasks) ?_latest[task],
    ];
    final snapshotEvents = HashSet<DownloadUpdate>.identity()
      ..addAll(snapshots);
    try {
      for (final update in snapshots) {
        yield update;
      }
      await for (final update in buffered.stream) {
        if (snapshotEvents.remove(update)) {
          continue;
        }
        yield update;
      }
    } finally {
      await subscription.cancel();
      if (!buffered.isClosed) {
        await buffered.close();
      }
    }
  }

  static List<DownloadTask> _identityUnique(List<DownloadTask> tasks) {
    final seen = HashSet<DownloadTask>.identity();
    return <DownloadTask>[
      for (final task in tasks)
        if (seen.add(task)) task,
    ];
  }
}
