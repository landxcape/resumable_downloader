import 'dart:async';
import 'dart:io';

import '../download_configuration.dart';
import '../download_request.dart';
import '../download_task.dart';
import '../scheduling/transfer_scheduler.dart';
import '../status/download_status.dart';
import '../status/download_update.dart';
import '../storage/file_transfer_storage.dart';
import '../transport/transfer_http_client.dart';
import '../transport/transfer_probe.dart';
import 'byte_range.dart';
import 'range_worker.dart';
import 'transfer_key.dart';
import 'transfer_plan.dart';

/// Runs the lifecycle of one V2 file transfer.
class TransferCoordinator {
  factory TransferCoordinator({
    required FileTransferStorage storage,
    required TransferHttpClient transport,
    required TransferProbe probe,
    DownloadConfiguration? configuration,
    TransferScheduler? scheduler,
  }) {
    final resolvedConfiguration = configuration ?? DownloadConfiguration();
    return TransferCoordinator._(
      storage: storage,
      transport: transport,
      probe: probe,
      configuration: resolvedConfiguration,
      scheduler: scheduler ?? TransferScheduler(resolvedConfiguration),
    );
  }

  TransferCoordinator._({
    required FileTransferStorage storage,
    required TransferHttpClient transport,
    required TransferProbe probe,
    required DownloadConfiguration configuration,
    required TransferScheduler scheduler,
  })  : _storage = storage,
        _transport = transport,
        _probe = probe,
        _configuration = configuration,
        _scheduler = scheduler;

  final FileTransferStorage _storage;
  final TransferHttpClient _transport;
  final TransferProbe _probe;
  final DownloadConfiguration _configuration;
  final TransferScheduler _scheduler;
  var _nextTaskId = 0;

  DownloadTask start(DownloadRequest request, {String? taskId}) {
    final resolvedTaskId = taskId ?? 'task-${++_nextTaskId}';
    final controller = DownloadTaskController(resolvedTaskId);
    unawaited(Future<void>.microtask(() => _run(controller, request)));
    return controller.task;
  }

  Future<void> _run(
    DownloadTaskController controller,
    DownloadRequest request,
  ) async {
    try {
      controller.emit(
        DownloadUpdate(
          taskId: controller.task.id,
          status: DownloadStatus.preparing,
          receivedBytes: 0,
        ),
      );
      final probeResult = await _probe.probe(request.url, headers: request.headers);
      final totalBytes = probeResult.totalBytes;
      if (totalBytes == null) {
        throw StateError('V2 single-stream transfers require a content length');
      }

      final key = TransferKey(controller.task.id.replaceAll('-', '_'));
      final partial = await _storage.createPartialFile(key, totalBytes: totalBytes);
      final plan = TransferPlan.create(
        totalBytes: totalBytes,
        probe: probeResult,
        configuration: _configuration,
      );
      controller.emit(
        DownloadUpdate(
          taskId: controller.task.id,
          status: DownloadStatus.downloading,
          receivedBytes: 0,
          totalBytes: totalBytes,
          activeRanges: plan.ranges.length,
        ),
      );
      if (plan.isMultipart) {
        _scheduler.enqueue(controller.task.id);
        final worker = RangeWorker(
          scheduler: _scheduler,
          transport: _transport,
          storage: _storage,
        );
        await Future.wait(
          plan.ranges.map(
            (range) => worker.run(
              transferId: controller.task.id,
              url: request.url,
              partial: partial,
              range: range,
              totalBytes: totalBytes,
              headers: request.headers,
            ),
          ),
        );
      } else {
        final response = await _transport.get(request.url, headers: request.headers);
        if (response.statusCode != HttpStatus.ok) {
          throw HttpException('Unexpected download status ${response.statusCode}');
        }
        await _storage.writeRange(
          partial,
          ByteRange(0, totalBytes - 1),
          response.body,
        );
      }
      final output = await _storage.finalize(
        partial,
        fileName: _fileNameFor(request),
      );
      controller.emit(
        DownloadUpdate(
          taskId: controller.task.id,
          status: DownloadStatus.completed,
          receivedBytes: totalBytes,
          totalBytes: totalBytes,
          completedRanges: plan.ranges.length,
          outputPath: output.path,
        ),
      );
      controller.complete(output);
    } catch (error, stackTrace) {
      controller.emit(
        DownloadUpdate(
          taskId: controller.task.id,
          status: DownloadStatus.failed,
          receivedBytes: 0,
          error: error,
        ),
      );
      controller.fail(error, stackTrace);
    }
  }

  String _fileNameFor(DownloadRequest request) {
    final supplied = request.fileName;
    if (supplied != null && supplied.isNotEmpty) {
      return supplied;
    }
    final segments = request.url.pathSegments;
    return segments.isEmpty || segments.last.isEmpty ? 'download.bin' : segments.last;
  }
}
