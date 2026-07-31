import 'dart:async';
import 'dart:io';

import '../download_configuration.dart';
import '../download_priority.dart';
import '../download_request.dart';
import '../download_task.dart';
import '../download_validation.dart';
import '../scheduling/transfer_scheduler.dart';
import '../status/download_status.dart';
import '../status/download_range_update.dart';
import '../status/download_update.dart';
import '../storage/file_transfer_storage.dart';
import '../storage/transfer_manifest.dart';
import '../support/download_exception.dart';
import '../support/retry_policy.dart';
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

  DownloadTask start(
    DownloadRequest request, {
    String? taskId,
    TransferKey? restoredKey,
    bool allowSourceUriChange = false,
    DownloadPriority Function()? currentPriority,
  }) {
    final resolvedTaskId = taskId ?? 'task-${++_nextTaskId}';
    final controller = DownloadTaskController(resolvedTaskId);
    final priority = currentPriority ?? () => DownloadPriority.normal;
    unawaited(
      Future<void>.microtask(
        () => _run(
          controller,
          request,
          restoredKey: restoredKey,
          allowSourceUriChange: allowSourceUriChange,
          currentPriority: priority,
        ),
      ),
    );
    return controller.task;
  }

  Future<void> _run(
    DownloadTaskController controller,
    DownloadRequest request, {
    TransferKey? restoredKey,
    required bool allowSourceUriChange,
    required DownloadPriority Function() currentPriority,
  }) async {
    var cancellation = TransferCancellation();
    Completer<void>? resumeSignal;
    var resumeRequested = false;
    controller.setCancelHandler(() async => cancellation.cancel());
    controller.setPauseHandler(() async => cancellation.pause());
    controller.setResumeHandler(() async {
      final signal = resumeSignal;
      if (signal != null && !signal.isCompleted) {
        signal.complete();
      } else if (cancellation.isPaused) {
        resumeRequested = true;
      }
    });
    _scheduler.enqueue(controller.task.id, priority: currentPriority());
    var isEnqueued = true;
    var retryAttempt = 0;
    try {
      while (true) {
        try {
          await _runAttempt(
            controller,
            request,
            cancellation,
            restoredKey: restoredKey,
            allowSourceUriChange: allowSourceUriChange,
          );
          return;
        } catch (error, stackTrace) {
          if (cancellation.isPaused &&
              !cancellation.isCancelled &&
              !_isValidationFailure(error)) {
            final signal = Completer<void>();
            resumeSignal = signal;
            if (resumeRequested) {
              resumeRequested = false;
              signal.complete();
            }
            _emitPausedUpdate(controller);
            _scheduler.complete(controller.task.id);
            isEnqueued = false;
            await Future.any<void>(<Future<void>>[
              signal.future,
              cancellation.whenCancelled,
            ]);
            resumeSignal = null;
            if (cancellation.isCancelled) {
              _completeTerminal(
                controller,
                error: const DownloadCancelledException(),
                stackTrace: stackTrace,
                isCancelled: true,
              );
              return;
            }
            cancellation = TransferCancellation();
            _scheduler.enqueue(controller.task.id, priority: currentPriority());
            isEnqueued = true;
            continue;
          }
          final isCancelled =
              cancellation.isCancelled || error is DownloadCancelledException;
          if (!isCancelled &&
              RetryPolicy.shouldRetry(error) &&
              retryAttempt < _configuration.maxRetries) {
            retryAttempt++;
            controller.emit(
              DownloadUpdate(
                taskId: controller.task.id,
                status: DownloadStatus.retrying,
                receivedBytes: 0,
                retryAttempt: retryAttempt,
                error: error,
              ),
            );
            await _waitBeforeRetry(retryAttempt, cancellation);
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
      if (isEnqueued) {
        _scheduler.complete(controller.task.id);
      }
    }
  }

  Future<void> _runAttempt(
    DownloadTaskController controller,
    DownloadRequest request,
    TransferCancellation cancellation, {
    TransferKey? restoredKey,
    required bool allowSourceUriChange,
  }) async {
    final outputFileName = _fileNameFor(request);
    controller.emit(
      DownloadUpdate(
        taskId: controller.task.id,
        status: DownloadStatus.preparing,
        receivedBytes: 0,
      ),
    );
    var existingOutput = await _storage.resolveExistingOutput(
      outputFileName,
      request.existingFilePolicy,
    );
    if (existingOutput != null) {
      final bytes = await existingOutput.length();
      try {
        await _runConfiguredValidation(
          controller,
          existingOutput,
          request: request,
          fileName: outputFileName,
          totalBytes: bytes,
        );
      } on DownloadIntegrityException {
        if (cancellation.isCancelled) {
          throw const DownloadCancelledException();
        }
        if (request.existingFilePolicy != ExistingFilePolicy.resume) {
          rethrow;
        }
        await existingOutput.delete();
        existingOutput = null;
      } on DownloadValidationException {
        if (cancellation.isCancelled) {
          throw const DownloadCancelledException();
        }
        if (request.existingFilePolicy != ExistingFilePolicy.resume) {
          rethrow;
        }
        await existingOutput.delete();
        existingOutput = null;
      }
    }
    if (cancellation.isCancelled) {
      throw const DownloadCancelledException();
    }
    if (cancellation.isPaused) {
      throw StateError('Transfer paused during validation');
    }
    if (existingOutput != null) {
      final bytes = await existingOutput.length();
      controller.emit(
        DownloadUpdate(
          taskId: controller.task.id,
          status: DownloadStatus.completed,
          receivedBytes: bytes,
          totalBytes: bytes,
          outputPath: existingOutput.path,
        ),
      );
      controller.complete(existingOutput);
      return;
    }
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

    final key = restoredKey ?? TransferKey.fromRequest(request);
    final plan = TransferPlan.create(
      totalBytes: totalBytes,
      probe: probeResult,
      configuration: _configuration,
    );
    TransferManifest? manifest;
    try {
      manifest = await _storage.readManifest(key);
    } on FormatException {
      await _storage.discard(key);
    }
    if (manifest != null &&
        !_isCompatibleManifest(
          manifest,
          request: request,
          outputFileName: outputFileName,
          totalBytes: totalBytes,
          probe: probeResult,
          plan: plan,
          allowSourceUriChange: allowSourceUriChange,
        )) {
      await _storage.discard(key);
      manifest = null;
    }
    File partial;
    try {
      partial = await _storage.openPartial(key, totalBytes: totalBytes);
    } on StateError {
      await _storage.discard(key);
      manifest = null;
      partial = await _storage.openPartial(key, totalBytes: totalBytes);
    }
    final receivedByRange = <ByteRange, int>{
      for (final range in plan.ranges) range: _receivedBytes(manifest, range),
    };
    final statusByRange = <ByteRange, DownloadStatus>{
      for (final range in plan.ranges)
        range: receivedByRange[range] == range.length
            ? DownloadStatus.completed
            : DownloadStatus.downloading,
    };
    final checkpointedByRange = Map<ByteRange, int>.from(receivedByRange);
    TransferManifest createManifest() => TransferManifest(
      key: key,
      sourceUri: request.url,
      outputFileName: outputFileName,
      totalBytes: totalBytes,
      restorationId: request.restorationId,
      expectedSha256: request.expectedSha256,
      entityTag: probeResult.entityTag,
      lastModified: probeResult.lastModified,
      ranges: plan.ranges
          .map(
            (range) => TransferRangeCheckpoint(
              range: range,
              receivedBytes: receivedByRange[range]!,
            ),
          )
          .toList(growable: false),
    );
    await _storage.writeManifest(createManifest());
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
          activeRanges: statusByRange.values
              .where((status) => status == DownloadStatus.downloading)
              .length,
          completedRanges: statusByRange.values
              .where((status) => status == DownloadStatus.completed)
              .length,
          outputPath: outputPath,
          ranges: ranges,
        ),
      );
    }

    emitProgress(force: true);
    final pendingRanges = plan.ranges
        .where((range) => receivedByRange[range] != range.length)
        .toList(growable: false);
    if (plan.isMultipart) {
      final worker = RangeWorker(
        scheduler: _scheduler,
        transport: _transport,
        storage: _storage,
      );
      await Future.wait(
        pendingRanges.map((range) {
          final initialReceivedBytes = receivedByRange[range]!;
          final requestRange = ByteRange(
            range.start + initialReceivedBytes,
            range.end,
          );
          return worker.run(
            transferId: controller.task.id,
            url: request.url,
            partial: partial,
            range: requestRange,
            totalBytes: totalBytes,
            headers: request.headers,
            cancellation: cancellation,
            onProgress: (receivedBytes) async {
              final totalReceivedBytes = initialReceivedBytes + receivedBytes;
              receivedByRange[range] = totalReceivedBytes;
              emitProgress();
              if (totalReceivedBytes - checkpointedByRange[range]! >=
                  _configuration.checkpointBytes) {
                checkpointedByRange[range] = totalReceivedBytes;
                await _storage.writeManifest(createManifest());
              }
            },
            onComplete: () async {
              receivedByRange[range] = range.length;
              checkpointedByRange[range] = range.length;
              statusByRange[range] = DownloadStatus.completed;
              emitProgress(force: true);
              await _storage.writeManifest(createManifest());
            },
          );
        }),
      );
    } else if (pendingRanges.isNotEmpty) {
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
          await response.body.drain<void>();
          throw DownloadHttpException(response.statusCode);
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
        await _storage.writeManifest(createManifest());
      } finally {
        await lease.release();
      }
    }
    if (cancellation.isCancelled) {
      throw const DownloadCancelledException();
    }
    if (cancellation.isPaused) {
      throw StateError('Transfer paused before finalization');
    }
    if (receivedByRange.entries.any(
      (entry) => entry.value != entry.key.length,
    )) {
      throw const DownloadIntegrityException(
        'Not all planned byte ranges completed before finalization',
      );
    }
    try {
      await _runConfiguredValidation(
        controller,
        partial,
        request: request,
        fileName: outputFileName,
        totalBytes: totalBytes,
      );
    } on DownloadIntegrityException {
      await _storage.discard(key);
      rethrow;
    } on DownloadValidationException {
      await _storage.discard(key);
      rethrow;
    }
    if (cancellation.isCancelled) {
      throw const DownloadCancelledException();
    }
    if (cancellation.isPaused) {
      throw StateError('Transfer paused during validation');
    }
    final output = await _storage.finalize(
      partial,
      fileName: outputFileName,
      expectedBytes: totalBytes,
    );
    await _storage.deleteManifest(key);
    emitProgress(
      force: true,
      taskStatus: DownloadStatus.completed,
      outputPath: output.path,
    );
    controller.complete(output);
  }

  Future<void> _validateFile(
    File file, {
    required DownloadRequest request,
    required String fileName,
    required int totalBytes,
  }) async {
    final expectedSha256 = request.expectedSha256;
    if (expectedSha256 != null) {
      await _storage.verifySha256(file, expectedSha256);
    }
    final validator = request.validator;
    if (validator == null) {
      return;
    }
    try {
      final isValid = await validator(
        DownloadValidationData(
          file: file,
          sourceUri: request.url,
          fileName: fileName,
          totalBytes: totalBytes,
        ),
      );
      if (!isValid) {
        throw const DownloadValidationException(
          'The configured download validator rejected the file.',
        );
      }
    } on DownloadValidationException {
      rethrow;
    } catch (error) {
      throw DownloadValidationException(
        'The configured download validator could not complete.',
        cause: error,
      );
    }
  }

  Future<void> _runConfiguredValidation(
    DownloadTaskController controller,
    File file, {
    required DownloadRequest request,
    required String fileName,
    required int totalBytes,
  }) async {
    if (request.expectedSha256 == null && request.validator == null) {
      return;
    }
    final latest = controller.lastUpdate;
    controller.emit(
      DownloadUpdate(
        taskId: controller.task.id,
        status: DownloadStatus.validating,
        receivedBytes: totalBytes,
        totalBytes: totalBytes,
        activeRanges: 0,
        completedRanges: latest?.completedRanges ?? 0,
        ranges: latest?.ranges ?? const <DownloadRangeUpdate>[],
      ),
    );
    await _validateFile(
      file,
      request: request,
      fileName: fileName,
      totalBytes: totalBytes,
    );
  }

  int _receivedBytes(TransferManifest? manifest, ByteRange range) {
    if (manifest == null) {
      return 0;
    }
    for (final checkpoint in manifest.ranges) {
      if (checkpoint.range == range) {
        return checkpoint.receivedBytes;
      }
    }
    return 0;
  }

  bool _isCompatibleManifest(
    TransferManifest manifest, {
    required DownloadRequest request,
    required String outputFileName,
    required int totalBytes,
    required TransferProbeResult probe,
    required TransferPlan plan,
    required bool allowSourceUriChange,
  }) {
    if ((!allowSourceUriChange && manifest.sourceUri != request.url) ||
        manifest.outputFileName != outputFileName ||
        manifest.totalBytes != totalBytes ||
        manifest.restorationId != request.restorationId ||
        manifest.expectedSha256 != request.expectedSha256 ||
        manifest.ranges.length != plan.ranges.length ||
        manifest.ranges.any(
          (checkpoint) => !plan.ranges.contains(checkpoint.range),
        )) {
      return false;
    }
    if (manifest.entityTag != null && manifest.entityTag != probe.entityTag) {
      return false;
    }
    return manifest.lastModified == null ||
        manifest.lastModified == probe.lastModified;
  }

  Future<void> _waitBeforeRetry(
    int retryAttempt,
    TransferCancellation cancellation,
  ) async {
    final delay = _configuration.retryDelay * retryAttempt;
    if (delay > Duration.zero) {
      await Future.any<void>(<Future<void>>[
        Future<void>.delayed(delay),
        cancellation.whenInterrupted,
      ]);
    }
  }

  void _emitPausedUpdate(DownloadTaskController controller) {
    final latest = controller.lastUpdate;
    controller.emit(
      DownloadUpdate(
        taskId: controller.task.id,
        status: DownloadStatus.paused,
        receivedBytes: latest?.receivedBytes ?? 0,
        totalBytes: latest?.totalBytes,
        activeRanges: 0,
        completedRanges: latest?.completedRanges ?? 0,
        ranges: latest?.ranges ?? const <DownloadRangeUpdate>[],
      ),
    );
  }

  void _completeTerminal(
    DownloadTaskController controller, {
    required Object error,
    required StackTrace stackTrace,
    required bool isCancelled,
  }) {
    final terminalError = isCancelled
        ? const DownloadCancelledException()
        : error;
    final latest = controller.lastUpdate;
    controller.emit(
      DownloadUpdate(
        taskId: controller.task.id,
        status: isCancelled ? DownloadStatus.cancelled : DownloadStatus.failed,
        receivedBytes: latest?.receivedBytes ?? 0,
        totalBytes: latest?.totalBytes,
        activeRanges: 0,
        completedRanges: latest?.completedRanges ?? 0,
        retryAttempt: latest?.retryAttempt ?? 0,
        error: terminalError,
        ranges: latest?.ranges ?? const <DownloadRangeUpdate>[],
      ),
    );
    controller.fail(terminalError, stackTrace);
  }

  bool _isValidationFailure(Object error) =>
      error is DownloadIntegrityException ||
      error is DownloadValidationException;

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
