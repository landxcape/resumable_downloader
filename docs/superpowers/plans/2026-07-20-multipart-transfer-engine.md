# Multipart Transfer Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a Flutter-first V2 downloader with fair, bounded file and multipart parallelism, verified resume support, task lifecycle updates, and an isolated legacy entry point.

**Architecture:** The new root API is a task-oriented `DownloadManager` backed by a scheduler, transfer coordinators, range workers, a Dio transport adapter, and versioned file storage. The current implementation remains runnable only through `resumable_downloader_legacy.dart`; it is never part of the V2 execution path and shares no public models with it.

**Tech Stack:** Flutter/Dart 3.7, Dio 5, `dart:io`, `path_provider`, `flutter_test`, in-process `HttpServer` test fixtures.

---

## File Map

```text
lib/
  resumable_downloader.dart                     V2-only root exports
  resumable_downloader_legacy.dart              legacy-only exports
  src/
    legacy/                                    existing API and models, frozen
    v2/
      download_manager.dart                    V2 facade
      download_configuration.dart              immutable limits and defaults
      download_request.dart                    immutable request data
      download_task.dart                       task handle and updates stream
      status/download_status.dart              lifecycle state enum
      status/download_update.dart              lifecycle payload
      scheduling/transfer_scheduler.dart       queue and fair connection leases
      scheduling/connection_lease.dart         release-once global slot handle
      transfers/transfer_key.dart              V2 identity and manifest key
      transfers/byte_range.dart                inclusive range value type
      transfers/transfer_plan.dart             single/multipart range planning
      transfers/transfer_state.dart            internal coordinator state
      transfers/transfer_coordinator.dart      one file transfer lifecycle
      transfers/range_worker.dart              one ranged streaming request
      transport/transfer_http_client.dart      testable HTTP interface
      transport/dio_transfer_http_client.dart  Dio streaming implementation
      transport/transfer_probe.dart            range/metadata validation
      transport/transfer_response.dart         response and validator types
      storage/transfer_storage.dart            storage contract
      storage/file_transfer_storage.dart       native file operations
      storage/transfer_manifest.dart           resumable V2 metadata
      storage/manifest_store.dart              manifest serialization
      support/download_exception.dart          typed terminal errors
      support/retry_policy.dart                retryability and delay decisions

test/
  support/range_test_server.dart               configurable local HTTP server
  support/temp_directory.dart                  test directory lifecycle helper
  legacy/legacy_entrypoint_test.dart           legacy import and basic legacy flow
  v2/models_test.dart                          request/config/status value tests
  v2/transfer_probe_test.dart                  protocol validation tests
  v2/file_transfer_storage_test.dart           files and manifests
  v2/transfer_coordinator_test.dart            single-stream lifecycle tests
  v2/transfer_scheduler_test.dart              limits and fairness tests
  v2/multipart_transfer_test.dart              end-to-end range assembly tests
  v2/resume_and_cancellation_test.dart         recovery and terminal cleanup
```

### Task 1: Isolate the legacy API

**Files:**
- Create: `lib/resumable_downloader_legacy.dart`
- Move: `lib/src/constants/` to `lib/src/legacy/constants/`
- Move: `lib/src/models/` to `lib/src/legacy/models/`
- Move: `lib/src/download_manager.dart` to `lib/src/legacy/download_manager.dart`
- Move: `lib/src/network_info.dart` to `lib/src/legacy/network_info.dart`
- Modify: `lib/src/legacy/models/download_task.dart`
- Create: `test/legacy/legacy_entrypoint_test.dart`

- [ ] **Step 1: Write the failing legacy entry-point compile test.**

```dart
import 'package:resumable_downloader/resumable_downloader_legacy.dart' as legacy;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy library exposes the current manager and models', () {
    final item = legacy.QueueItem(url: 'https://example.test/file.bin');
    final manager = legacy.DownloadManager(subDir: 'legacy');

    expect(item.url, 'https://example.test/file.bin');
    expect(manager, isA<legacy.DownloadManager>());
  });
}
```

- [ ] **Step 2: Run the legacy test to verify it fails.**

Run: `flutter test test/legacy/legacy_entrypoint_test.dart`

Expected: FAIL because `resumable_downloader_legacy.dart` does not exist.

- [ ] **Step 3: Move and expose the legacy library without changing its behavior.**

Use `git mv` for the listed source groups. Update only relative imports made invalid
by the move. Create `lib/resumable_downloader_legacy.dart` with the current public
exports:

```dart
export 'src/legacy/constants/enums.dart' show FileExistsStrategy, LogLevel;
export 'src/legacy/constants/typedefs.dart' show LogCallback;
export 'src/legacy/download_manager.dart' show DownloadManager;
export 'src/legacy/models/download_progress.dart'
    show DownloadProgress, DownloadProgressExtension;
export 'src/legacy/models/log_record.dart' show LogRecord;
export 'src/legacy/models/queue_item.dart' show QueueItem;
```

Replace the legacy task's import of the root package with direct relative imports.
Do not change legacy runtime behavior.

- [ ] **Step 4: Run legacy analysis and test.**

Run: `dart analyze lib/resumable_downloader_legacy.dart lib/src/legacy/models/download_task.dart && flutter test test/legacy/legacy_entrypoint_test.dart`

Expected: both commands succeed.

- [ ] **Step 5: Commit the isolated legacy surface.**

```bash
git add lib/resumable_downloader_legacy.dart lib/src/legacy test/legacy/legacy_entrypoint_test.dart
git commit -m "feat: expose legacy downloader api"
```

### Task 2: Build the V2 public contract

**Files:**
- Create: `lib/src/v2/download_configuration.dart`
- Create: `lib/src/v2/download_request.dart`
- Create: `lib/src/v2/download_task.dart`
- Create: `lib/src/v2/status/download_status.dart`
- Create: `lib/src/v2/status/download_update.dart`
- Create: `lib/src/v2/support/download_exception.dart`
- Create: `test/v2/models_test.dart`

- [ ] **Step 1: Write failing value-model tests.**

```dart
test('configuration validates every connection limit', () {
  expect(
    () => DownloadConfiguration(maxConcurrentConnections: 0),
    throwsArgumentError,
  );
});

test('update reports unknown progress as null', () {
  const update = DownloadUpdate(
    taskId: 'task',
    status: DownloadStatus.downloading,
    receivedBytes: 12,
  );

  expect(update.progress, isNull);
});
```

- [ ] **Step 2: Run the model test to verify it fails.**

Run: `flutter test test/v2/models_test.dart`

Expected: FAIL because V2 model types do not exist.

- [ ] **Step 3: Implement immutable public types.**

Implement these exact essentials:

```dart
class DownloadConfiguration {
  const DownloadConfiguration({
    this.maxConcurrentDownloads = 3,
    this.maxConcurrentConnections = 6,
    this.maxConnectionsPerDownload = 4,
    this.minimumBytesPerPart = 8 * 1024 * 1024,
    this.maxRetries = 3,
  });
}

class DownloadRequest {
  const DownloadRequest({
    required this.url,
    this.fileName,
    this.subdirectory,
    this.headers = const <String, String>{},
    this.existingFilePolicy = ExistingFilePolicy.resume,
  });
}

enum ExistingFilePolicy { resume, replace, keepExisting, fail }

enum DownloadStatus {
  queued, preparing, downloading, retrying, completed, failed, cancelled,
}
```

`ExistingFilePolicy` is a V2 type independent from the legacy enum.
`DownloadUpdate.progress` returns `null` when `totalBytes` is absent or zero.
`DownloadTask` exposes `id`, `Stream<DownloadUpdate> get updates`,
`Future<File> get result`, and `Future<void> cancel()`. Its constructor is
internal to V2.

- [ ] **Step 4: Run model tests and static analysis.**

Run: `flutter test test/v2/models_test.dart && dart analyze lib/src/v2`

Expected: both commands succeed.

- [ ] **Step 5: Commit public V2 models.**

```bash
git add lib/src/v2 test/v2/models_test.dart
git commit -m "feat: add v2 download task models"
```

### Task 3: Add deterministic local HTTP test infrastructure

**Files:**
- Create: `test/support/range_test_server.dart`
- Create: `test/support/temp_directory.dart`
- Modify: `test/v2/models_test.dart`
- Create: `test/v2/transfer_probe_test.dart`

- [ ] **Step 1: Write a failing probe test against a real local server.**

```dart
test('probe verifies a 206 response and content range', () async {
  final server = await RangeTestServer.start(bytes: fixtureBytes);
  addTearDown(server.close);

  final result = await probe.probe(Uri.parse(server.url));

  expect(result.totalBytes, fixtureBytes.length);
  expect(result.supportsRanges, isTrue);
});
```

- [ ] **Step 2: Run the test to verify it fails.**

Run: `flutter test test/v2/transfer_probe_test.dart`

Expected: FAIL because the test server and probe do not exist.

- [ ] **Step 3: Implement the reusable local server fixture.**

`RangeTestServer` must serve deterministic byte data and support test-configurable
behaviors: `HEAD`, valid `206` range responses, full `200` responses, malformed
`Content-Range`, dropped streams, unknown content length, response delay, and
mutable `ETag`. Parse only `bytes=start-end` requests. `TempDirectory` creates a
unique directory and recursively removes that exact directory during teardown.

- [ ] **Step 4: Implement the transport interface and probe.**

Create `TransferHttpClient` with metadata and streamed-range methods. Create a
minimal fake implementation in the probe test, then implement `TransferProbe` so
that it validates the requested start/end offsets, response status, total length,
and validators. A server that ignores a range is reported as `supportsRanges: false`.

- [ ] **Step 5: Run probe tests.**

Run: `flutter test test/v2/transfer_probe_test.dart`

Expected: valid range, ignored range, malformed range, and unknown-size cases pass.

- [ ] **Step 6: Commit test infrastructure and probe.**

```bash
git add test/support test/v2/transfer_probe_test.dart lib/src/v2/transport
git commit -m "feat: add v2 transfer probing"
```

### Task 4: Implement V2 storage and resume manifests

**Files:**
- Create: `lib/src/v2/transfers/transfer_key.dart`
- Create: `lib/src/v2/transfers/byte_range.dart`
- Create: `lib/src/v2/storage/transfer_manifest.dart`
- Create: `lib/src/v2/storage/manifest_store.dart`
- Create: `lib/src/v2/storage/transfer_storage.dart`
- Create: `lib/src/v2/storage/file_transfer_storage.dart`
- Create: `test/v2/file_transfer_storage_test.dart`

- [ ] **Step 1: Write failing storage tests.**

```dart
test('independent handles write non-overlapping ranges into one partial file', () async {
  final target = await storage.createPartialFile(key, totalBytes: 6);
  await Future.wait([
    storage.writeRange(target, const ByteRange(0, 2), [0, 1, 2]),
    storage.writeRange(target, const ByteRange(3, 5), [3, 4, 5]),
  ]);

  expect(await target.readAsBytes(), [0, 1, 2, 3, 4, 5]);
});
```

- [ ] **Step 2: Run storage tests to verify they fail.**

Run: `flutter test test/v2/file_transfer_storage_test.dart`

Expected: FAIL because V2 storage types do not exist.

- [ ] **Step 3: Implement versioned V2 partial paths and manifest serialization.**

Use a V2-specific hidden directory below the selected output directory, such as
`.resumable_downloader_v2/`. The manifest filename is derived from a stable
cryptographic task-key digest, never the raw URL. Persist format version, output
path, total bytes, validators, completed ranges, and request identity. Use JSON via
`dart:convert`; reject unknown format versions and invalid range maps.

- [ ] **Step 4: Implement safe file operations.**

Preallocate known-length files. Each `writeRange` opens and closes its own
`RandomAccessFile`, seeks to the supplied offset, and verifies that streamed bytes
do not exceed the range. Finalize only after the caller has verified total bytes;
rename within the same directory and delete the manifest. Cleanup removes only the
V2 partial file and its paired manifest.

- [ ] **Step 5: Run storage tests.**

Run: `flutter test test/v2/file_transfer_storage_test.dart`

Expected: concurrent range writes, manifest round trip, stale manifest rejection,
finalization, and targeted cleanup pass.

- [ ] **Step 6: Commit V2 storage.**

```bash
git add lib/src/v2/storage lib/src/v2/transfers/transfer_key.dart lib/src/v2/transfers/byte_range.dart test/v2/file_transfer_storage_test.dart
git commit -m "feat: add v2 resumable transfer storage"
```

### Task 5: Deliver verified single-stream V2 transfers

**Files:**
- Create: `lib/src/v2/transfers/transfer_plan.dart`
- Create: `lib/src/v2/transfers/transfer_state.dart`
- Create: `lib/src/v2/transfers/transfer_coordinator.dart`
- Create: `lib/src/v2/support/retry_policy.dart`
- Create: `lib/src/v2/transport/dio_transfer_http_client.dart`
- Create: `test/v2/transfer_coordinator_test.dart`

- [ ] **Step 1: Write failing single-stream lifecycle tests.**

```dart
test('single stream emits terminal updates and atomically returns the file', () async {
  final task = coordinator.start(request);
  final updates = await task.updates.toList();
  final file = await task.result;

  expect(await file.readAsBytes(), fixtureBytes);
  expect(updates.map((item) => item.status), containsAllInOrder([
    DownloadStatus.preparing,
    DownloadStatus.downloading,
    DownloadStatus.completed,
  ]));
});
```

- [ ] **Step 2: Run the coordinator test to verify it fails.**

Run: `flutter test test/v2/transfer_coordinator_test.dart`

Expected: FAIL because the coordinator is absent.

- [ ] **Step 3: Implement Dio streaming and a single-range plan.**

`DioTransferHttpClient` uses `ResponseType.stream`, merged request headers,
explicit `Range` headers only for planned ranges, and a child `CancelToken` per
worker. It exposes headers, status, and byte stream without using `Dio.download()`.
`TransferPlan.single` is selected for unverified range support, unknown size, or
files below 16 MiB.

- [ ] **Step 4: Implement the coordinator's terminal-state rules.**

The coordinator creates a V2 task key, probes first, writes the single stream to
storage, emits aggregate progress, and resolves exactly once. Map transport and
storage errors to `DownloadException`. Use `RetryPolicy` with at most three retries,
exponential delays, and jitter; do not retry cancellation or protocol failures.

- [ ] **Step 5: Run the coordinator tests.**

Run: `flutter test test/v2/transfer_coordinator_test.dart`

Expected: success, unknown size, transient retry, permanent failure, cancellation,
and no-network request-failure tests pass.

- [ ] **Step 6: Commit single-stream V2 transfers.**

```bash
git add lib/src/v2/transfers lib/src/v2/support lib/src/v2/transport/dio_transfer_http_client.dart test/v2/transfer_coordinator_test.dart
git commit -m "feat: add v2 single stream transfers"
```

### Task 6: Add the fair global connection scheduler

**Files:**
- Create: `lib/src/v2/scheduling/connection_lease.dart`
- Create: `lib/src/v2/scheduling/transfer_scheduler.dart`
- Create: `test/v2/transfer_scheduler_test.dart`

- [ ] **Step 1: Write failing scheduling tests.**

```dart
test('scheduler gives each queued transfer a first lease before an extra lease', () async {
  scheduler.enqueue(largeA);
  scheduler.enqueue(smallB);

  final first = await scheduler.acquire(largeA.id);
  final second = await scheduler.acquire(smallB.id);

  expect(first.transferId, largeA.id);
  expect(second.transferId, smallB.id);
});
```

- [ ] **Step 2: Run scheduler tests to verify they fail.**

Run: `flutter test test/v2/transfer_scheduler_test.dart`

Expected: FAIL because scheduler types do not exist.

- [ ] **Step 3: Implement lease accounting.**

`ConnectionLease.release()` is idempotent and releases exactly one global slot.
The scheduler tracks active file count, active global connection count, and active
connections per task. Every wait path is awakened after a release, cancellation, or
dispose.

- [ ] **Step 4: Implement fairness and limits.**

Admission respects `maxConcurrentDownloads`. A task's first range has priority over
additional ranges. After all eligible active transfers have one lease, grant spare
leases round-robin without exceeding `maxConcurrentConnections` or
`maxConnectionsPerDownload`. Dispose cancels pending lease requests with a terminal
manager-disposed error.

- [ ] **Step 5: Run scheduler tests.**

Run: `flutter test test/v2/transfer_scheduler_test.dart`

Expected: global, per-file, file-admission, round-robin, cancellation, and
release-once tests pass.

- [ ] **Step 6: Commit the scheduler.**

```bash
git add lib/src/v2/scheduling test/v2/transfer_scheduler_test.dart
git commit -m "feat: add fair v2 connection scheduling"
```

### Task 7: Add multipart workers and resume validation

**Files:**
- Create: `lib/src/v2/transfers/range_worker.dart`
- Modify: `lib/src/v2/transfers/transfer_plan.dart`
- Modify: `lib/src/v2/transfers/transfer_coordinator.dart`
- Create: `test/v2/multipart_transfer_test.dart`
- Create: `test/v2/resume_and_cancellation_test.dart`

- [ ] **Step 1: Write failing multipart assembly and limit tests.**

```dart
test('eligible files assemble four verified ranges without exceeding limits', () async {
  final task = manager.enqueue(largeRequest);
  final file = await task.result;

  expect(await file.readAsBytes(), fixtureBytes);
  expect(server.maximumConcurrentRequests, lessThanOrEqualTo(6));
  expect(server.maximumConcurrentRequestsFor(task.id), lessThanOrEqualTo(4));
});
```

- [ ] **Step 2: Run multipart tests to verify they fail.**

Run: `flutter test test/v2/multipart_transfer_test.dart test/v2/resume_and_cancellation_test.dart`

Expected: FAIL because range workers and multipart planning do not exist.

- [ ] **Step 3: Implement deterministic multipart planning.**

For verified files of at least 16 MiB, calculate
`min(maxConnectionsPerDownload, totalBytes ~/ minimumBytesPerPart)` non-overlapping
inclusive ranges. Never create more than one range for an ineligible file. Persist
the range map before starting workers.

- [ ] **Step 4: Implement range workers and aggregate progress.**

Each worker acquires one scheduler lease, issues a validated `206` request, writes
only to its assigned range, updates manifest progress after durable writes, and
releases the lease in `finally`. The coordinator aggregates bytes across workers,
emits active/completed range counts, and resolves only after all workers complete.

- [ ] **Step 5: Implement resume and protocol safety.**

On a repeat request, load only a matching V2 manifest. Re-probe validators before
using recorded ranges. Resume incomplete ranges from their next missing byte; delete
the V2 partial data and restart if validator, total length, path, or format differs.
Treat `200` for a planned range, malformed `Content-Range`, and byte overflow as
protocol failures that cannot append to the partial file.

- [ ] **Step 6: Run end-to-end V2 transfer tests.**

Run: `flutter test test/v2/multipart_transfer_test.dart test/v2/resume_and_cancellation_test.dart`

Expected: multipart assembly, competing file fairness, restart after ETag change,
resume after disconnect, cancellation of all children, and cleanup tests pass.

- [ ] **Step 7: Commit multipart support.**

```bash
git add lib/src/v2/transfers test/v2/multipart_transfer_test.dart test/v2/resume_and_cancellation_test.dart
git commit -m "feat: add multipart resumable transfers"
```

### Task 8: Add the V2 manager facade and cut over the root library

**Files:**
- Create: `lib/src/v2/download_manager.dart`
- Modify: `lib/resumable_downloader.dart`
- Create: `test/v2/download_manager_test.dart`

- [ ] **Step 1: Write failing facade tests.**

```dart
test('root manager exposes task-oriented enqueue and manager-wide updates', () async {
  final manager = DownloadManager(subdirectory: temp.path);
  final task = manager.enqueue(DownloadRequest(url: server.url));

  expect(manager.updates, emits(isA<DownloadUpdate>()));
  expect(await task.result, isA<File>());
});
```

- [ ] **Step 2: Run facade tests to verify they fail.**

Run: `flutter test test/v2/download_manager_test.dart`

Expected: FAIL because the V2 facade is absent.

- [ ] **Step 3: Implement manager lifecycle and root exports.**

`DownloadManager` resolves its base directory using `path_provider` when one is not
provided, owns scheduler/coordinator construction, multiplexes manager-wide updates,
and rejects enqueue after disposal. Export only V2 manager, config, request, task,
status/update, exception, and `ExistingFilePolicy` from
`lib/resumable_downloader.dart`. Do not export legacy types from the root library.

- [ ] **Step 4: Run legacy and V2 entrypoint tests together.**

Run: `flutter test test/legacy/legacy_entrypoint_test.dart test/v2/download_manager_test.dart`

Expected: both entry points compile independently; V2 never imports legacy code.

- [ ] **Step 5: Commit API cutover.**

```bash
git add lib/resumable_downloader.dart lib/src/v2/download_manager.dart test/v2/download_manager_test.dart
git commit -m "feat: expose v2 downloader api"
```

### Task 9: Publish-readiness documentation and release verification

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `pubspec.yaml`
- Modify: `example/lib/main.dart`
- Create: `docs/migrating-from-legacy.md`

- [ ] **Step 1: Write the migration guide and README examples.**

Document V2 configuration, task lifecycle updates, cancellation, automatic
multipart eligibility, native-platform scope, and legacy entrypoint usage. Include this
minimal V2 example:

```dart
final task = manager.enqueue(DownloadRequest(url: url));
task.updates.listen((update) => setState(() => latest = update));
final file = await task.result;
```

State explicitly that browser and OS background transfers are not supported in
`0.1.0`.

- [ ] **Step 2: Update the example application to use only V2.**

Show enqueue, live status, cancellation via `DownloadTask.cancel()`, and final-file
deletion. Do not add background-mode UI or an in-app explanation panel.

- [ ] **Step 3: Update package metadata.**

Set `version: 0.1.0`; update description and keywords to mention multipart and
task status; preserve Dio and native Flutter dependencies. Add changelog sections
for breaking V2 API, legacy entry point, multipart behavior, and migration guide.

- [ ] **Step 4: Run the release gate.**

Run: `dart format --output=none --set-exit-if-changed lib test example/lib && dart analyze && flutter test && flutter analyze example`

Expected: all commands exit zero. Resolve every failure before publishing.

- [ ] **Step 5: Inspect package contents and publish dry run.**

Run: `dart pub publish --dry-run`

Expected: package validation succeeds and includes the README, changelog, license,
legacy entrypoint, V2 API, migration guide, and no generated build artifacts.

- [ ] **Step 6: Commit release-ready V2.**

```bash
git add README.md CHANGELOG.md pubspec.yaml example/lib/main.dart docs/migrating-from-legacy.md
git commit -m "docs: prepare v2 downloader release"
```

## Final Verification Checklist

- [ ] Root API imports without legacy symbols.
- [ ] Legacy API imports through `resumable_downloader_legacy.dart` and retains current behavior.
- [ ] Every V2 task reaches exactly one terminal status and resolves its result once.
- [ ] No schedule permits more files, global requests, or per-file requests than configured.
- [ ] Multipart output equals server fixture bytes exactly.
- [ ] A server that does not honor range requests cannot corrupt partial output.
- [ ] V2 partial files and manifests never overlap with legacy `.tmp` paths.
- [ ] Analysis, tests, example analysis, and pub dry run all pass.
