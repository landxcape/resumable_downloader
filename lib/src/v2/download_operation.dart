import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'download_task.dart';
import 'status/download_operation_metrics.dart';
import 'status/download_status.dart';
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
    _latestMetrics = _buildMetrics();
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
  final StreamController<DownloadOperationMetrics> _metricsLive =
      StreamController<DownloadOperationMetrics>.broadcast(sync: true);
  final Map<DownloadTask, DownloadUpdate> _latest =
      <DownloadTask, DownloadUpdate>{};
  final List<StreamSubscription<DownloadUpdate>> _subscriptions =
      <StreamSubscription<DownloadUpdate>>[];
  late final List<DownloadTask> _uniqueTasks;
  DownloadOperationMetrics? _latestMetrics;
  var _remainingUniqueTasks = 0;

  /// Completes with files in the same order as [tasks].
  Future<List<File>> get result => _result;

  /// Whether every unique task has reached a terminal result.
  bool get isCompleted => tasks.every((task) => task.isCompleted);

  /// Most recent aggregate metrics snapshot for this operation.
  DownloadOperationMetrics get latestMetrics => _latestMetrics!;

  /// Current snapshots followed by live updates from only this operation.
  ///
  /// Each listener observes the current state independently. Re-listening does
  /// not enqueue or restart any task.
  Stream<DownloadUpdate> get updates => _watchUpdates();

  /// Current aggregate metrics followed by future operation snapshots.
  ///
  /// Each listener receives its own current snapshot. Listening never starts
  /// or repeats transfer work.
  Stream<DownloadOperationMetrics> get metrics => _watchMetrics();

  void _bindUniqueTasks() {
    _remainingUniqueTasks = _uniqueTasks.length;
    if (_remainingUniqueTasks == 0) {
      unawaited(_live.close());
      unawaited(_metricsLive.close());
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
            _emitMetrics();
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
      unawaited(_metricsLive.close());
    }
  }

  void _emitMetrics() {
    final metrics = _buildMetrics();
    _latestMetrics = metrics;
    if (!_metricsLive.isClosed) {
      _metricsLive.add(metrics);
    }
  }

  DownloadOperationMetrics _buildMetrics() {
    final taskIds = <String>[];
    final taskUpdates = <String, DownloadUpdate>{};
    var receivedBytes = 0;
    var totalBytes = 0;
    var totalKnown = true;
    var measurableSpeed = 0.0;
    var hasMeasurableSpeed = false;

    for (final task in _uniqueTasks) {
      taskIds.add(task.id);
      final update = _latest[task] ?? task.latestUpdate;
      if (update == null) {
        totalKnown = false;
        continue;
      }
      taskUpdates[task.id] = update;
      receivedBytes += update.receivedBytes;
      final taskTotal = update.totalBytes;
      if (taskTotal == null) {
        totalKnown = false;
      } else if (totalKnown) {
        totalBytes += taskTotal;
      }
      if (update.status == DownloadStatus.downloading &&
          update.bytesPerSecond != null) {
        measurableSpeed += update.bytesPerSecond!;
        hasMeasurableSpeed = true;
      }
    }

    return DownloadOperationMetrics(
      operationId: id,
      receivedBytes: receivedBytes,
      totalBytes: totalKnown ? totalBytes : null,
      bytesPerSecond: hasMeasurableSpeed ? measurableSpeed : null,
      taskIds: taskIds,
      taskUpdates: taskUpdates,
    );
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

  Stream<DownloadOperationMetrics> _watchMetrics() async* {
    final buffered = StreamController<DownloadOperationMetrics>();
    final subscription = _metricsLive.stream.listen(
      buffered.add,
      onError: buffered.addError,
      onDone: buffered.close,
    );
    final snapshot = latestMetrics;
    final snapshotEvents = HashSet<DownloadOperationMetrics>.identity()
      ..add(snapshot);
    try {
      yield snapshot;
      await for (final metrics in buffered.stream) {
        if (snapshotEvents.remove(metrics)) {
          continue;
        }
        yield metrics;
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
