import 'dart:async';
import 'dart:io';

import '../download_configuration.dart';
import '../download_request.dart';
import '../download_task.dart';
import '../scheduling/transfer_scheduler.dart';
import '../status/download_status.dart';
import '../status/download_range_update.dart';
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
  }) : _storage = storage,
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
    final cancellation = TransferCancellation();
    controller.setCancelHandler(() async => cancellation.cancel());
    _scheduler.enqueue(controller.task.id);
    try {
      for (var retryAttempt = 0; ; retryAttempt++) {
        try {
          await _runAttempt(controller, request, cancellation);
          return;
        } catch (error, stackTrace) {
          final isCancelled =
              cancellation.isCancelled || error is DownloadCancelledException;
          if (!isCancelled && retryAttempt < _configuration.maxRetries) {
            final nextRetryAttempt = retryAttempt + 1;
            controller.emit(
              DownloadUpdate(
                taskId: controller.task.id,
                status: DownloadStatus.retrying,
                receivedBytes: 0,
                retryAttempt: nextRetryAttempt,
                error: error,
              ),
            );
            await _waitBeforeRetry(nextRetryAttempt, cancellation);
            if (!cancellation.isCancelled) {
              continue;
            }
            _completeTerminal(
              controller,
              error: const DownloadCancelledException(),
              stackTrace: stackTrace,
              isCancelled: true,
            );
            return;
          }
          _completeTerminal(
            controller,
            error: error,
            stackTrace: stackTrace,
            isCancelled: isCancelled,
          );
          return;
        }
      }
    } finally {
      _scheduler.complete(controller.task.id);
    }
  }

  Future<void> _runAttempt(
    DownloadTaskController controller,
    DownloadRequest request,
    TransferCancellation cancellation,
  ) async {
    controller.emit(
      DownloadUpdate(
        taskId: controller.task.id,
        status: DownloadStatus.preparing,
        receivedBytes: 0,
      ),
    );
    final probeLease = await _scheduler.acquire(controller.task.id);
    final probeResult =
        await (() async {
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
    final partial = await _storage.createPartialFile(
      key,
      totalBytes: totalBytes,
    );
    final plan = TransferPlan.create(
      totalBytes: totalBytes,
      probe: probeResult,
      configuration: _configuration,
    );
    final receivedByRange = <ByteRange, int>{
      for (final range in plan.ranges) range: 0,
    };
    final statusByRange = <ByteRange, DownloadStatus>{
      for (final range in plan.ranges) range: DownloadStatus.downloading,
    };
    DateTime? lastProgressEmission;

    void emitProgress({
      bool force = false,
      DownloadStatus taskStatus = DownloadStatus.downloading,
      String? outputPath,
    }) {
      final now = DateTime.now();
      if (!force &&
          lastProgressEmission != null &&
          now.difference(lastProgressEmission!) <
              const Duration(milliseconds: 100)) {
        return;
      }
      lastProgressEmission = now;
      final ranges = plan.ranges
          .map(
            (range) => DownloadRangeUpdate(
              startByte: range.start,
              endByte: range.end,
              receivedBytes: receivedByRange[range]!,
              status: statusByRange[range]!,
            ),
          )
          .toList(growable: false);
      controller.emit(
        DownloadUpdate(
          taskId: controller.task.id,
          status: taskStatus,
          receivedBytes: receivedByRange.values.fold(
            0,
            (sum, value) => sum + value,
          ),
          totalBytes: totalBytes,
          activeRanges:
              statusByRange.values
                  .where((status) => status == DownloadStatus.downloading)
                  .length,
          completedRanges:
              statusByRange.values
                  .where((status) => status == DownloadStatus.completed)
                  .length,
          outputPath: outputPath,
          ranges: ranges,
        ),
      );
    }

    emitProgress(force: true);
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
            onProgress: (receivedBytes) {
              receivedByRange[range] = receivedBytes;
              emitProgress();
            },
            onComplete: () {
              receivedByRange[range] = range.length;
              statusByRange[range] = DownloadStatus.completed;
              emitProgress(force: true);
            },
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
          throw HttpException(
            'Unexpected download status ${response.statusCode}',
          );
        }
        await _storage.writeRange(
          partial,
          ByteRange(0, totalBytes - 1),
          response.body,
          onProgress: (receivedBytes) {
            final range = plan.ranges.single;
            receivedByRange[range] = receivedBytes;
            emitProgress();
          },
        );
        final range = plan.ranges.single;
        receivedByRange[range] = range.length;
        statusByRange[range] = DownloadStatus.completed;
        emitProgress(force: true);
      } finally {
        await lease.release();
      }
    }
    final output = await _storage.finalize(
      partial,
      fileName: _fileNameFor(request),
    );
    emitProgress(
      force: true,
      taskStatus: DownloadStatus.completed,
      outputPath: output.path,
    );
    controller.complete(output);
  }

  Future<void> _waitBeforeRetry(
    int retryAttempt,
    TransferCancellation cancellation,
  ) async {
    final delay = _configuration.retryDelay * retryAttempt;
    if (delay > Duration.zero) {
      await Future.any<void>(<Future<void>>[
        Future<void>.delayed(delay),
        cancellation.whenCancelled,
      ]);
    }
  }

  void _completeTerminal(
    DownloadTaskController controller, {
    required Object error,
    required StackTrace stackTrace,
    required bool isCancelled,
  }) {
    final terminalError =
        isCancelled ? const DownloadCancelledException() : error;
    controller.emit(
      DownloadUpdate(
        taskId: controller.task.id,
        status: isCancelled ? DownloadStatus.cancelled : DownloadStatus.failed,
        receivedBytes: 0,
        error: terminalError,
      ),
    );
    controller.fail(terminalError, stackTrace);
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
