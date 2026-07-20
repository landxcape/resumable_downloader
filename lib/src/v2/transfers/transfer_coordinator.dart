import 'dart:async';
import 'dart:io';

import '../download_configuration.dart';
import '../download_request.dart';
import '../download_task.dart';
import '../scheduling/transfer_scheduler.dart';
import '../status/download_status.dart';
import '../status/download_update.dart';
import '../storage/file_transfer_storage.dart';
import '../support/download_exception.dart';
import '../transport/transfer_cancellation.dart';
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
    var registeredWithScheduler = false;
    final cancellation = TransferCancellation();
    controller.setCancelHandler(() async => cancellation.cancel());
    try {
      _scheduler.enqueue(controller.task.id);
      registeredWithScheduler = true;
      controller.emit(
        DownloadUpdate(
          taskId: controller.task.id,
          status: DownloadStatus.preparing,
          receivedBytes: 0,
        ),
      );
      final probeLease = await _scheduler.acquire(controller.task.id);
      final probeResult = await (() async {
        try {
          return await _probe.probe(
            request.url,
            headers: request.headers,
            cancellation: cancellation,
          );
        } finally {
          await probeLease.release();
        }
      })();
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
              cancellation: cancellation,
            ),
          ),
        );
      } else {
        final lease = await _scheduler.acquire(controller.task.id);
        try {
          final response = await _transport.get(
            request.url,
            headers: request.headers,
            cancellation: cancellation,
          );
          if (cancellation.isCancelled) {
            throw const DownloadCancelledException();
          }
          if (response.statusCode != HttpStatus.ok) {
            throw HttpException('Unexpected download status ${response.statusCode}');
          }
          await _storage.writeRange(
            partial,
            ByteRange(0, totalBytes - 1),
            response.body,
          );
        } finally {
          await lease.release();
        }
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
      final isCancelled = cancellation.isCancelled || error is DownloadCancelledException;
      controller.emit(
        DownloadUpdate(
          taskId: controller.task.id,
          status: isCancelled ? DownloadStatus.cancelled : DownloadStatus.failed,
          receivedBytes: 0,
          error: isCancelled ? const DownloadCancelledException() : error,
        ),
      );
      controller.fail(
        isCancelled ? const DownloadCancelledException() : error,
        stackTrace,
      );
    } finally {
      if (registeredWithScheduler) {
        _scheduler.complete(controller.task.id);
      }
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
