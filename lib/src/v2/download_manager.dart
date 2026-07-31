import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'download_configuration.dart';
import 'download_operation.dart';
import 'download_priority.dart';
import 'download_request.dart';
import 'download_task.dart';
import 'pending_download.dart';
import 'scheduling/transfer_scheduler.dart';
import 'status/download_status.dart';
import 'status/download_update.dart';
import 'storage/file_transfer_storage.dart';
import 'transport/dio_transfer_http_client.dart';
import 'transport/transfer_probe.dart';
import 'transfers/transfer_coordinator.dart';
import 'transfers/transfer_key.dart';

/// V2 download manager for native Flutter applications.
class DownloadManager {
  /// Creates a foreground download manager.
  ///
  /// [baseDirectory] defaults to the application documents directory.
  DownloadManager({
    Directory? baseDirectory,
    this.subdirectory,
    DownloadConfiguration? configuration,
  }) : _baseDirectory = baseDirectory,
       configuration = configuration ?? DownloadConfiguration(),
       _updates = StreamController<DownloadUpdate>.broadcast(sync: true),
       _transport = DioTransferHttpClient(),
       _scheduler = TransferScheduler(configuration ?? DownloadConfiguration());

  final Directory? _baseDirectory;

  /// Optional directory segment applied to every request managed by this instance.
  final String? subdirectory;

  /// Scheduler, retry, and checkpoint settings used by this manager.
  final DownloadConfiguration configuration;
  final StreamController<DownloadUpdate> _updates;
  final DioTransferHttpClient _transport;
  final TransferScheduler _scheduler;
  final Map<TransferKey, _ManagedTransfer> _activeTransfers =
      <TransferKey, _ManagedTransfer>{};
  var _nextOperationId = 0;
  var _nextTaskId = 0;
  var _disposed = false;

  /// Lifecycle snapshots for every task accepted by this manager.
  Stream<DownloadUpdate> get updates => _updates.stream;

  /// Starts a transfer and returns its task handle immediately.
  DownloadTask enqueue(DownloadRequest request) {
    return _enqueue(request, priority: DownloadPriority.normal);
  }

  DownloadTask _enqueue(
    DownloadRequest request, {
    required DownloadPriority priority,
  }) {
    if (_disposed) {
      throw StateError('DownloadManager has been disposed');
    }
    final key = TransferKey.fromRequest(request);
    final active = _activeTransfers[key];
    if (active != null && active.isReusable) {
      if (active.promote(priority)) {
        _scheduler.promote(active.task.id, active.priority);
      }
      return active.task;
    }
    if (active != null) {
      _activeTransfers.remove(key);
    }
    final controller = DownloadTaskController('manager-task-${++_nextTaskId}');
    final managed = _ManagedTransfer(
      controller: controller,
      priority: priority,
    );
    _activeTransfers[key] = managed;
    unawaited(
      _start(managed, request).whenComplete(() {
        if (identical(_activeTransfers[key], managed)) {
          _activeTransfers.remove(key);
        }
      }),
    );
    return managed.task;
  }

  /// Starts a transfer and resolves with its final local file.
  Future<File> download(DownloadRequest request) => enqueue(request).result;

  /// Starts a logical operation containing exactly [requests].
  ///
  /// Equivalent active requests reuse their existing physical task. A
  /// foreground operation promotes future scheduling for those shared tasks
  /// without preempting active connection leases.
  DownloadOperation startOperation(
    Iterable<DownloadRequest> requests, {
    DownloadPriority priority = DownloadPriority.normal,
  }) {
    if (_disposed) {
      throw StateError('DownloadManager has been disposed');
    }
    final requestList = List<DownloadRequest>.unmodifiable(requests);
    final tasks = <DownloadTask>[
      for (final request in requestList) _enqueue(request, priority: priority),
    ];
    return createDownloadOperation(
      id: 'manager-operation-${++_nextOperationId}',
      tasks: tasks,
    );
  }

  /// Lists durable transfers that were not finalized before the app stopped.
  Future<List<PendingDownload>> pendingDownloads() async {
    final artifacts = await _discoverPending();
    return artifacts
        .map((artifact) => artifact.pending)
        .toList(growable: false);
  }

  /// Resolves and resumes durable transfers with fresh request credentials.
  ///
  /// The resolver must supply the same [DownloadRequest.restorationId] when
  /// one was stored. Its URL and headers may be refreshed safely.
  Future<List<DownloadTask>> restorePending(
    FutureOr<DownloadRequest?> Function(PendingDownload pending) resolve,
  ) async {
    if (_disposed) {
      throw StateError('DownloadManager has been disposed');
    }
    final tasks = <DownloadTask>[];
    for (final artifact in await _discoverPending()) {
      final pending = artifact.pending;
      final request = await resolve(pending);
      if (request == null) {
        continue;
      }
      if (pending.restorationId != request.restorationId) {
        throw ArgumentError.value(
          request.restorationId,
          'request.restorationId',
          'must match the stored transfer restorationId',
        );
      }
      final active = _activeTransfers[artifact.key];
      if (active != null && active.isReusable) {
        tasks.add(active.task);
        continue;
      }
      if (active != null) {
        _activeTransfers.remove(artifact.key);
      }
      final controller = DownloadTaskController(
        'manager-task-${++_nextTaskId}',
      );
      final managed = _ManagedTransfer(
        controller: controller,
        priority: DownloadPriority.normal,
      );
      _activeTransfers[artifact.key] = managed;
      unawaited(
        _start(
          managed,
          request,
          directory: artifact.directory,
          restoredKey: artifact.key,
          allowSourceUriChange: true,
        ).whenComplete(() {
          if (identical(_activeTransfers[artifact.key], managed)) {
            _activeTransfers.remove(artifact.key);
          }
        }),
      );
      tasks.add(managed.task);
    }
    return tasks;
  }

  /// Deletes the final output and/or resumable staging data for [request].
  ///
  /// Set [cancelActive] to cancel an active transfer before deleting its data.
  Future<void> deleteArtifacts(
    DownloadRequest request, {
    bool deleteOutput = true,
    bool deleteStaging = true,
    bool cancelActive = false,
  }) async {
    final key = TransferKey.fromRequest(request);
    final activeTask = _activeTransfers[key]?.task;
    if (activeTask != null && !activeTask.isCompleted) {
      if (!cancelActive) {
        throw StateError('Cannot delete artifacts for an active transfer');
      }
      await activeTask.cancel();
      try {
        await activeTask.result;
      } on Object {
        // A cancelled task reports its terminal error through [result].
      }
    }
    if (activeTask != null) {
      _activeTransfers.remove(key);
    }
    final directory = await _resolveDirectory(request);
    await FileTransferStorage(directory).deleteArtifacts(
      key,
      fileName: _fileNameFor(request),
      deleteOutput: deleteOutput,
      deleteStaging: deleteStaging,
    );
  }

  /// Releases the manager update stream and prevents new tasks from starting.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _activeTransfers.clear();
    await _updates.close();
  }

  Future<void> _start(
    _ManagedTransfer managed,
    DownloadRequest request, {
    Directory? directory,
    TransferKey? restoredKey,
    bool allowSourceUriChange = false,
  }) async {
    final controller = managed.controller;
    StreamSubscription<DownloadUpdate>? subscription;
    DownloadTask? innerTask;
    var cancelRequested = false;
    var pauseRequested = false;
    controller.setCancelHandler(() async {
      cancelRequested = true;
      await innerTask?.cancel();
    });
    controller.setPauseHandler(() async {
      pauseRequested = true;
      await innerTask?.pause();
    });
    controller.setResumeHandler(() async {
      pauseRequested = false;
      await innerTask?.resume();
    });
    try {
      final resolvedDirectory = directory ?? await _resolveDirectory(request);
      final coordinator = TransferCoordinator(
        storage: FileTransferStorage(resolvedDirectory),
        transport: _transport,
        probe: TransferProbe(_transport),
        configuration: configuration,
        scheduler: _scheduler,
      );
      innerTask = coordinator.start(
        request,
        taskId: controller.task.id,
        restoredKey: restoredKey,
        allowSourceUriChange: allowSourceUriChange,
        currentPriority: () => managed.priority,
      );
      subscription = innerTask.updates.listen((update) {
        controller.emit(update);
        if (!_updates.isClosed) {
          _updates.add(update);
        }
      });
      if (cancelRequested) {
        await innerTask.cancel();
      }
      if (pauseRequested) {
        await innerTask.pause();
      }
      final file = await innerTask.result;
      controller.complete(file);
    } catch (error, stackTrace) {
      controller.fail(error, stackTrace);
    } finally {
      await subscription?.cancel();
    }
  }

  Future<Directory> _resolveDirectory(DownloadRequest request) async {
    var directory = _baseDirectory ?? await getApplicationDocumentsDirectory();
    for (final segment in <String?>[subdirectory, request.subdirectory]) {
      if (segment == null || segment.isEmpty) {
        continue;
      }
      if (segment.contains('/') || segment.contains('\\')) {
        throw ArgumentError.value(
          segment,
          'subdirectory',
          'must be one segment',
        );
      }
      directory = Directory('${directory.path}/$segment');
    }
    await directory.create(recursive: true);
    return directory;
  }

  Future<List<StoredPendingDownload>> _discoverPending() async {
    var root = _baseDirectory ?? await getApplicationDocumentsDirectory();
    if (subdirectory != null && subdirectory!.isNotEmpty) {
      root = Directory('${root.path}/$subdirectory');
    }
    return FileTransferStorage.discoverPending(root);
  }

  String _fileNameFor(DownloadRequest request) {
    final supplied = request.fileName;
    if (supplied != null && supplied.isNotEmpty) {
      return supplied;
    }
    final segments = request.url.pathSegments;
    return segments.isEmpty || segments.last.isEmpty
        ? 'download.bin'
        : segments.last;
  }
}

final class _ManagedTransfer {
  _ManagedTransfer({required this.controller, required this.priority});

  final DownloadTaskController controller;
  DownloadPriority priority;

  DownloadTask get task => controller.task;

  bool get isReusable {
    if (task.isCompleted) {
      return false;
    }
    return switch (task.latestUpdate?.status) {
      DownloadStatus.completed ||
      DownloadStatus.failed ||
      DownloadStatus.cancelled => false,
      _ => true,
    };
  }

  bool promote(DownloadPriority requested) {
    if (priority.index >= requested.index) {
      return false;
    }
    priority = requested;
    return true;
  }
}
