# V2 Durable Resume and File Inventory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make V2 downloads durable across app restarts with same-volume staging, range-aware resume, explicit pause/resume controls, and an example that displays real files rather than a separately persisted task list.

**Architecture:** Each request receives a stable, filesystem-safe key derived from its canonical source and target. V2 stores a preallocated partial file and atomically updated manifest in a hidden `.resumable_downloader_v2` directory beside the visible destination file; successful finalization remains a same-volume rename. The example scans the visible destination directory for completed files and keeps only active tasks in memory.

**Tech Stack:** Flutter/Dart 3.7+, Dio 5, `dart:convert`, `dart:io`, `package:crypto`, `path_provider`, `flutter_test`, in-process `HttpServer` fixtures.

---

## Decisions Locked In

- Persistent staging is the default. Do not use the OS temporary directory for resumable transfers.
- The staging directory lives beneath the final destination directory, so finalize is an atomic rename instead of a cross-volume copy.
- A manifest never persists request headers. Callers provide current headers again when resuming, preventing credentials from being written to disk.
- Completed final files are the example app's persisted inventory. Queued, failed, and cancelled cards are intentionally in-memory only until V2 can reconstruct them from manifests.
- A restart after an interrupted transfer is a **resume from durable state**, not an automatic background restart. The caller or user explicitly enqueues/resumes it.
- The existing Flutter-generated changes in `example/android/gradle.properties` and `example/pubspec.lock` must be reviewed independently and never staged incidentally with this plan.

## File Map

```text
lib/src/v2/
  download_request.dart                         stable resume identity inputs
  download_task.dart                            pause/resume task controls
  status/download_status.dart                   paused lifecycle state
  status/download_update.dart                   durable range and resume metadata
  transfers/transfer_key.dart                   SHA-256 request/target key
  transfers/range_worker.dart                   offset-aware range continuation
  transfers/transfer_coordinator.dart           restore, pause, resume, finalize
  transport/transfer_cancellation.dart          separate stop and pause signals
  storage/file_transfer_storage.dart             same-volume staging operations
  storage/transfer_manifest.dart                versioned range checkpoints
  storage/manifest_store.dart                   atomic manifest read/write/delete
  support/retry_policy.dart                     retry only transient failures

test/
  support/range_test_server.dart                dropped-stream and validator controls
  v2/file_transfer_storage_test.dart            atomic manifest and staging tests
  v2/transfer_coordinator_test.dart             retry, pause, and durable resume tests
  v2/resume_manifest_test.dart                  schema and validator compatibility tests

example/lib/
  download_directory.dart                       scans and deletes visible completed files
  main.dart                                     live task list plus disk-file inventory
example/test/
  download_directory_test.dart                  directory scanning and deletion tests
  main_app_test.dart                            restored files and delete UI tests
```

### Task 1: Define Stable Storage Identity and Manifest Schema

**Files:**
- Modify: `pubspec.yaml`
- Modify: `lib/src/v2/download_request.dart`
- Modify: `lib/src/v2/transfers/transfer_key.dart`
- Modify: `lib/src/v2/storage/transfer_manifest.dart`
- Modify: `lib/src/v2/storage/manifest_store.dart`
- Create: `test/v2/resume_manifest_test.dart`

- [ ] **Step 1: Write failing stable-key and manifest-identity tests.**

```dart
test('equivalent requests produce the same durable key', () {
  final request = DownloadRequest(
    url: Uri.parse('https://example.test/archive.bin?version=2'),
    fileName: 'archive.bin',
    subdirectory: 'downloads',
  );

  expect(TransferKey.fromRequest(request).value, hasLength(64));
  expect(TransferKey.fromRequest(request), TransferKey.fromRequest(request));
});

test('manifest round trips request identity and partial range checkpoints', () {
  final manifest = TransferManifest(
    key: TransferKey.fromRequest(request),
    sourceUri: request.url,
    outputFileName: 'archive.bin',
    totalBytes: 64,
    ranges: [
      TransferRangeCheckpoint(range: ByteRange(0, 31), receivedBytes: 32),
      TransferRangeCheckpoint(range: ByteRange(32, 63), receivedBytes: 8),
    ],
  );

  expect(TransferManifest.fromJson(manifest.toJson()), manifest);
});
```

- [ ] **Step 2: Run the new manifest test and verify it fails.**

Run: `flutter test test/v2/resume_manifest_test.dart`

Expected: FAIL because `TransferKey.fromRequest` and range checkpoints do not exist.

- [ ] **Step 3: Add the minimal durable schema.**

Add `crypto: ^3.0.6` to `pubspec.yaml`. Implement the following public-internal shapes:

```dart
class TransferKey {
  factory TransferKey.fromRequest(DownloadRequest request) {
    final identity = jsonEncode(<String, String?>{
      'url': request.url.toString(),
      'fileName': request.fileName,
      'subdirectory': request.subdirectory,
    });
    return TransferKey(sha256.convert(utf8.encode(identity)).toString());
  }
}

class TransferRangeCheckpoint {
  const TransferRangeCheckpoint({
    required this.range,
    required this.receivedBytes,
  }) : assert(receivedBytes >= 0 && receivedBytes <= range.length);

  final ByteRange range;
  final int receivedBytes;
  bool get isComplete => receivedBytes == range.length;
}
```

Upgrade `TransferManifest` to include `sourceUri`, `outputFileName`, `totalBytes`, optional `entityTag`/`lastModified`, and every planned range checkpoint. Reject malformed ranges, duplicate ranges, checkpoints beyond their range length, and unknown schema versions. Do not serialize `DownloadRequest.headers`.

`ManifestStore.write` must write `<key>.json.tmp`, flush it, then rename it to `<key>.json`; a partial JSON write must never replace a valid manifest.

- [ ] **Step 4: Run manifest tests and formatter.**

Run: `dart format lib/src/v2 test/v2/resume_manifest_test.dart && flutter test test/v2/resume_manifest_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit the schema.**

```bash
git add pubspec.yaml pubspec.lock lib/src/v2/download_request.dart \
  lib/src/v2/transfers/transfer_key.dart lib/src/v2/storage \
  test/v2/resume_manifest_test.dart
git commit -m "feat: add durable v2 transfer manifests"
```

### Task 2: Make Staging Durable and Same-Volume

**Files:**
- Modify: `lib/src/v2/storage/file_transfer_storage.dart`
- Modify: `test/v2/file_transfer_storage_test.dart`

- [ ] **Step 1: Write failing storage tests.**

```dart
test('opens the stable partial path without truncating existing bytes', () async {
  final first = await storage.openPartial(key, totalBytes: 16);
  await first.writeAsBytes(<int>[1, 2, 3], flush: true);

  final reopened = await storage.openPartial(key, totalBytes: 16);

  expect(await reopened.length(), 16);
  expect((await reopened.readAsBytes()).take(3), <int>[1, 2, 3]);
});

test('finalize moves a partial into the visible destination and removes its manifest', () async {
  final partial = await storage.openPartial(key, totalBytes: 4);
  await partial.writeAsBytes(<int>[1, 2, 3, 4]);

  final output = await storage.finalize(partial, fileName: 'archive.bin');

  expect(output.path, '${directory.path}/archive.bin');
  expect(await partial.exists(), isFalse);
});
```

- [ ] **Step 2: Run storage tests and verify they fail.**

Run: `flutter test test/v2/file_transfer_storage_test.dart`

Expected: FAIL because `createPartialFile` truncates existing partial data.

- [ ] **Step 3: Implement non-destructive staging APIs.**

Replace `createPartialFile` with `openPartial(TransferKey key, {required int totalBytes})`. It creates `.resumable_downloader_v2/<key>.partial` only when absent, preallocates it once, and verifies an existing file length equals `totalBytes`. Add `discard(key)` to delete exactly the partial and manifest for a task. Keep `finalize` as a rename from the hidden directory to the direct child of the caller's destination directory.

- [ ] **Step 4: Run storage tests.**

Run: `flutter test test/v2/file_transfer_storage_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit durable staging.**

```bash
git add lib/src/v2/storage/file_transfer_storage.dart test/v2/file_transfer_storage_test.dart
git commit -m "feat: preserve v2 partial staging files"
```

### Task 3: Resume Validated Ranges After a New Enqueue

**Files:**
- Modify: `lib/src/v2/transfers/range_worker.dart`
- Modify: `lib/src/v2/transfers/transfer_coordinator.dart`
- Modify: `lib/src/v2/storage/transfer_manifest.dart`
- Modify: `test/support/range_test_server.dart`
- Modify: `test/v2/transfer_coordinator_test.dart`

- [ ] **Step 1: Write the failing range-resume test.**

```dart
test('a new task resumes a checkpointed range instead of requesting it twice', () async {
  final first = coordinator.start(request);
  await server.waitForRangeBytes(start: 0, received: 16);
  await first.cancel();

  final resumed = coordinator.start(request);
  final file = await resumed.result;

  expect(await file.readAsBytes(), fixtureBytes);
  expect(server.requestedRanges, contains(ByteRange(16, 31)));
  expect(server.requestedRanges, isNot(contains(ByteRange(0, 31))));
});
```

- [ ] **Step 2: Run the focused test and verify it fails.**

Run: `flutter test test/v2/transfer_coordinator_test.dart --plain-name "a new task resumes a checkpointed range instead of requesting it twice"`

Expected: FAIL because every new task generates a task-ID key and starts at byte zero.

- [ ] **Step 3: Restore and validate durable state before scheduling work.**

`TransferCoordinator` must:

1. Probe the server before trusting a manifest.
2. Use a manifest only when its source URI, total length, and any persisted `ETag`/`Last-Modified` validator match the new probe.
3. Delete stale partial/manifest data when those values do not match.
4. Build workers only for checkpoints where `receivedBytes < range.length`.
5. Request `ByteRange(range.start + receivedBytes, range.end)` and write at that same file offset.
6. Atomically checkpoint received bytes after each configured write threshold and always after a completed range.
7. Delete the manifest only after final rename succeeds.

Update `RangeWorker.run` to accept `requestRange` and `writeRange`; validate `Content-Range` against `requestRange`, but report progress relative to the complete planned range.

- [ ] **Step 4: Add validator-mismatch coverage.**

```dart
test('changed entity tag discards stale partial state before restarting', () async {
  await createInterruptedTransfer(entityTag: '"v1"');
  server.entityTag = '"v2"';

  final output = await coordinator.start(request).result;

  expect(await output.readAsBytes(), fixtureBytes);
  expect(server.requestedRanges, contains(ByteRange(0, 31)));
});
```

- [ ] **Step 5: Run coordinator tests and commit.**

Run: `flutter test test/v2/transfer_coordinator_test.dart test/v2/file_transfer_storage_test.dart`

Expected: PASS.

```bash
git add lib/src/v2/transfers lib/src/v2/storage test/support/range_test_server.dart test/v2
git commit -m "feat: resume durable v2 byte ranges"
```

### Task 4: Add Explicit Pause and Resume to a Live Task

**Files:**
- Modify: `lib/src/v2/download_task.dart`
- Modify: `lib/src/v2/status/download_status.dart`
- Modify: `lib/src/v2/transfers/transfer_coordinator.dart`
- Modify: `lib/src/v2/transport/transfer_cancellation.dart`
- Modify: `test/v2/transfer_coordinator_test.dart`

- [ ] **Step 1: Write failing pause/resume lifecycle tests.**

```dart
test('pause checkpoints progress, releases network work, and leaves result pending', () async {
  final task = coordinator.start(request);
  await server.waitForRangeBytes(start: 0, received: 16);

  await task.pause();

  expect(await task.updates.firstWhere((u) => u.status == DownloadStatus.paused), isNotNull);
  expect(task.result, isNot(completes));
});

test('resume continues the same task from its manifest checkpoint', () async {
  await task.pause();
  await task.resume();

  expect(await task.result, isA<File>());
});
```

- [ ] **Step 2: Run the pause/resume test and verify it fails.**

Run: `flutter test test/v2/transfer_coordinator_test.dart --plain-name "pause checkpoints progress, releases network work, and leaves result pending"`

Expected: FAIL because `DownloadTask` only exposes `cancel()`.

- [ ] **Step 3: Implement a non-terminal pause state.**

Add `paused` to `DownloadStatus`, and add `Future<void> pause()` / `Future<void> resume()` to `DownloadTask`. Do not implement pause by completing `result` with an error. The coordinator must cancel only active transport requests, flush the manifest, emit `paused`, release all scheduler leases, await a resume signal, and restart its plan from the manifest when resumed. `cancel()` while paused must complete the task with `DownloadCancelledException` and retain the partial/manifest for a future new enqueue.

- [ ] **Step 4: Run all coordinator tests.**

Run: `flutter test test/v2/transfer_coordinator_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit task controls.**

```bash
git add lib/src/v2/download_task.dart lib/src/v2/status/download_status.dart \
  lib/src/v2/transfers/transfer_coordinator.dart \
  lib/src/v2/transport/transfer_cancellation.dart test/v2/transfer_coordinator_test.dart
git commit -m "feat: add v2 task pause and resume"
```

### Task 5: Use Disk Inventory in the Example Instead of Task-History Persistence

**Files:**
- Create: `example/lib/download_directory.dart`
- Modify: `example/lib/main.dart`
- Create: `example/test/download_directory_test.dart`
- Modify: `example/test/main_app_test.dart`

- [ ] **Step 1: Write failing file-inventory tests.**

```dart
test('lists direct visible files and ignores the hidden staging directory', () async {
  await File('${directory.path}/complete.bin').writeAsBytes(<int>[1, 2]);
  await Directory('${directory.path}/.resumable_downloader_v2').create();
  await File('${directory.path}/.resumable_downloader_v2/task.partial')
      .writeAsBytes(<int>[3]);

  final files = await inventory.listCompleted();

  expect(files.single.name, 'complete.bin');
});

test('deleting an inventory item removes the final file', () async {
  final file = File('${directory.path}/complete.bin');
  await file.writeAsBytes(<int>[1]);

  await inventory.delete(DownloadedFile.fromFile(file));

  expect(await file.exists(), isFalse);
});
```

- [ ] **Step 2: Run the inventory test and verify it fails.**

Run: `cd example && flutter test test/download_directory_test.dart`

Expected: FAIL because the inventory types do not exist.

- [ ] **Step 3: Implement the filesystem repository.**

`DownloadDirectory` resolves `getApplicationDocumentsDirectory()/transfer_lab`, lists only direct regular files, returns immutable `DownloadedFile(path, name, sizeBytes, modifiedAt)`, and deletes only a selected direct child after validating its canonical path remains inside the destination directory. It must never list or delete `.resumable_downloader_v2` staging content.

`DownloadLabPage` loads this inventory at startup and after a live task completes. Keep active task cards in memory. Do not add `shared_preferences`, a JSON history file, or automatic re-enqueue behavior.

- [ ] **Step 4: Add delete UI coverage.**

```dart
testWidgets('deleting a completed file requires confirmation', (tester) async {
  final inventory = FakeDownloadDirectory.withFiles(<DownloadedFile>[fixture]);
  await tester.pumpWidget(MainApp(downloadDirectory: inventory));

  await tester.tap(find.byTooltip('Delete file'));
  expect(find.text('Delete downloaded file?'), findsOneWidget);
  await tester.tap(find.text('Delete'));

  expect(inventory.deletedPaths, contains(fixture.path));
});
```

- [ ] **Step 5: Run example tests and commit.**

Run: `cd example && flutter test && flutter analyze`

Expected: PASS.

```bash
git add example/lib example/test
git commit -m "feat: show downloaded files in example"
```

### Task 6: Harden Retry, Finalization, and Release Evidence

**Files:**
- Create: `lib/src/v2/support/retry_policy.dart`
- Modify: `lib/src/v2/transfers/transfer_coordinator.dart`
- Modify: `lib/src/v2/transport/transfer_probe.dart`
- Modify: `test/v2/transfer_coordinator_test.dart`
- Modify: `test/v2/transfer_probe_test.dart`
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `pubspec.yaml`

- [ ] **Step 1: Write failing retry classification tests.**

```dart
test('does not retry a 404 response', () async {
  server.responseStatus = HttpStatus.notFound;
  final task = coordinator.start(request);

  await expectLater(task.result, throwsA(isA<DioException>()));
  expect(server.requestCount, lessThanOrEqualTo(2));
});

test('retries a dropped connection and succeeds', () async {
  server.dropFirstResponse = true;
  final file = await coordinator.start(request).result;

  expect(await file.readAsBytes(), fixtureBytes);
});
```

- [ ] **Step 2: Run the focused retry test and verify it fails.**

Run: `flutter test test/v2/transfer_coordinator_test.dart --plain-name "does not retry a 404 response"`

Expected: FAIL because current V2 retries every non-cancellation error.

- [ ] **Step 3: Add a small explicit retry policy.**

Implement `RetryPolicy.shouldRetry(Object error)` with these rules: retry connection/time-out/DNS errors and HTTP `408`, `429`, and `5xx`; do not retry `4xx` other than those two, validation failures, output-exists errors, manifest format errors, or cancellation. Keep `DownloadConfiguration.maxRetries` and `retryDelay` as the only public retry controls for this release.

- [ ] **Step 4: Run package and example verification.**

Run:

```bash
dart format lib test example/lib example/test
dart analyze
flutter test
cd example && flutter analyze && flutter test
```

Expected: all commands pass.

- [ ] **Step 5: Document and prepare an unreleased V2 preview.**

Document the V2 import, explicit legacy import, staging layout, pause/resume semantics, retry policy, and example workflow. Raise the package SDK constraints to Flutter `>=3.29.3` and Dart `^3.7.2`; set version `0.1.0-dev.1` only when the API/docs are complete and all verification is green. Do not publish in this task.

- [ ] **Step 6: Commit release evidence.**

```bash
git add lib/src/v2 README.md CHANGELOG.md pubspec.yaml pubspec.lock test example
git commit -m "docs: prepare v2 preview release"
```

## Merge Gate

Do not merge this branch into `main` until all of the following are true:

1. A local `HttpServer` suite proves multipart assembly, retry classification, pause/resume, durable resume after a new enqueue, validator mismatch reset, cancellation during backoff, and manifest cleanup after finalization.
2. `dart analyze`, root `flutter test`, example `flutter analyze`, and example `flutter test` pass from a clean checkout.
3. The example shows real completed files after a restart, supports confirmed deletion, and never exposes hidden staging files as completed downloads.
4. A controlled benchmark records better aggregate throughput or lower completion time than legacy for a range-enabled local fixture while respecting global/per-file connection caps. Keep the benchmark output in the PR or release notes; do not use an uncontrolled public speed-test host as evidence.
5. README, changelog, version, SDK bounds, and V2/legacy migration guidance accurately match the shipped behavior.

## Plan Review

- **Spec coverage:** Same-volume durable staging is Tasks 1-2; restart-safe byte-range resume is Task 3; live pause/resume is Task 4; filesystem-backed example list and actual delete are Task 5; retry correctness, documentation, SDK/version preparation, and merge evidence are Task 6.
- **No duplicate persistence:** Task 5 deliberately scans disk and does not add a preferences/history store.
- **Type consistency:** `TransferRangeCheckpoint`, `TransferKey.fromRequest`, `DownloadDirectory`, and `DownloadedFile` are introduced before later tasks use them.
- **Deferred scope:** Background execution, checksum APIs, encrypted manifests, and an OS-temp download mode are intentionally excluded until the durable core is proven.
