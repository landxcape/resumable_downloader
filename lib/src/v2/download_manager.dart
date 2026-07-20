import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'download_configuration.dart';
import 'download_request.dart';
import 'download_task.dart';
import 'scheduling/transfer_scheduler.dart';
import 'status/download_update.dart';
import 'storage/file_transfer_storage.dart';
import 'transport/dio_transfer_http_client.dart';
import 'transport/transfer_probe.dart';
import 'transfers/transfer_coordinator.dart';

/// V2 download manager for native Flutter applications.
class DownloadManager {
  DownloadManager({
    Directory? baseDirectory,
    this.subdirectory,
    DownloadConfiguration? configuration,
  })  : _baseDirectory = baseDirectory,
        configuration = configuration ?? DownloadConfiguration(),
        _updates = StreamController<DownloadUpdate>.broadcast(sync: true),
        _transport = DioTransferHttpClient(),
        _scheduler = TransferScheduler(configuration ?? DownloadConfiguration());

  final Directory? _baseDirectory;
  final String? subdirectory;
  final DownloadConfiguration configuration;
  final StreamController<DownloadUpdate> _updates;
  final DioTransferHttpClient _transport;
  final TransferScheduler _scheduler;
  var _nextTaskId = 0;
  var _disposed = false;

  /// Lifecycle snapshots for every task accepted by this manager.
  Stream<DownloadUpdate> get updates => _updates.stream;

  /// Starts a transfer and returns its task handle immediately.
  DownloadTask enqueue(DownloadRequest request) {
    if (_disposed) {
      throw StateError('DownloadManager has been disposed');
    }
    final controller = DownloadTaskController('manager-task-${++_nextTaskId}');
    unawaited(_start(controller, request));
    return controller.task;
  }

  /// Starts a transfer and resolves with its final local file.
  Future<File> download(DownloadRequest request) => enqueue(request).result;

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _updates.close();
  }

  Future<void> _start(
    DownloadTaskController controller,
    DownloadRequest request,
  ) async {
    StreamSubscription<DownloadUpdate>? subscription;
    DownloadTask? innerTask;
    var cancelRequested = false;
    controller.setCancelHandler(() async {
      cancelRequested = true;
      await innerTask?.cancel();
    });
    try {
      final directory = await _resolveDirectory(request);
      final coordinator = TransferCoordinator(
        storage: FileTransferStorage(directory),
        transport: _transport,
        probe: TransferProbe(_transport),
        configuration: configuration,
        scheduler: _scheduler,
      );
      innerTask = coordinator.start(request, taskId: controller.task.id);
      subscription = innerTask.updates.listen((update) {
        controller.emit(update);
        if (!_updates.isClosed) {
          _updates.add(update);
        }
      });
      if (cancelRequested) {
        await innerTask.cancel();
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
        throw ArgumentError.value(segment, 'subdirectory', 'must be one segment');
      }
      directory = Directory('${directory.path}/$segment');
    }
    await directory.create(recursive: true);
    return directory;
  }
}
