# resumable_downloader

A Flutter-first download manager for reliable foreground file transfers. V2
supports bounded concurrent files, multipart HTTP range downloads, durable
resume, pause/resume, integrity checks, and authenticated restoration.

## V2

The default library exports V2:

```dart
import 'package:resumable_downloader/resumable_downloader.dart';
```

Create a manager and enqueue a task:

```dart
final manager = DownloadManager(
  subdirectory: 'downloads',
  configuration: DownloadConfiguration(
    maxConcurrentDownloads: 3,
    maxConcurrentConnections: 6,
    maxConnectionsPerDownload: 4,
    minimumBytesPerPart: 8 * 1024 * 1024,
  ),
);

final task = manager.enqueue(
  DownloadRequest(
    url: Uri.parse('https://example.com/archive.zip'),
    fileName: 'archive.zip',
  ),
);

task.updates.listen((update) {
  print('${update.status}: ${update.receivedBytes}/${update.totalBytes}');
});

final file = await task.result;
await manager.dispose();
```

When the server honors byte ranges, V2 splits eligible files into ranges and
writes them directly into one staged file. It falls back to one stream when a
server ignores range requests. `maxConcurrentDownloads` bounds files,
`maxConcurrentConnections` bounds all HTTP work, and
`maxConnectionsPerDownload` bounds each file. `maxRetries`, `retryDelay`, and
`checkpointBytes` control transient retries and durable progress checkpoints.

## Task Controls

```dart
await task.pause();
await task.resume();
await task.cancel();
```

Use `DownloadStatus` and `DownloadRangeUpdate` from `task.updates` to render
aggregate and per-part progress. `DownloadTask.result` completes with the final
file or fails with a typed `DownloadException`.

## Existing Output And Deletion

`ExistingFilePolicy.resume` is the default. A completed output is reused;
`replace` removes it before downloading again; `keepExisting` reuses it; and
`fail` reports a conflict.

```dart
final request = DownloadRequest(
  url: url,
  fileName: 'archive.zip',
  existingFilePolicy: ExistingFilePolicy.replace,
);

await manager.deleteArtifacts(request, cancelActive: true);
```

`deleteArtifacts` removes the request's V2 staged partial/manifest and, by
default, its final output file.

## Integrity

V2 validates range lengths before finalization. Optionally require SHA-256:

```dart
final request = DownloadRequest(
  url: url,
  fileName: 'release.zip',
  expectedSha256: '64-character-lowercase-sha256-hex-digest',
);
```

On a checksum mismatch, V2 raises `DownloadIntegrityException` and discards the
staged state rather than exposing a file with unverified contents.

## Custom Validation

Add an app-owned check when a checksum alone is not enough, such as signature,
archive, media, or file-format verification:

```dart
final request = DownloadRequest(
  url: url,
  fileName: 'release.zip',
  expectedSha256: expectedDigest,
  validator: (data) async {
    return verifyReleaseSignature(data.file);
  },
);
```

The validator runs after configured SHA-256 validation. Return `true` to
accept the file or `false` to reject it. `data.file` is a lightweight `File`
handle, not a copy of the downloaded bytes, but it must be treated as
read-only because V2 owns its lifecycle.

For a new transfer, a rejection deletes the staged file and manifest. V2 also
validates retained `resume` and `keepExisting` outputs before returning them:
`resume` deletes a rejected output and downloads it again, while `keepExisting`
reports the rejection without deleting that output. `replace` removes an
existing output before downloading and validating a fresh one; `fail` reports
an existing-output conflict before validation.

V2 reports rejection through `DownloadValidationException` on both
`task.result` and `DownloadUpdate.error`. The parent application owns the
domain reason: throw `DownloadValidationException` from the callback to retain
a specific explanation. Other callback errors are wrapped with that error as
the exception's `cause`.

## Authenticated Restoration

V2 stores partial bytes and non-sensitive manifest metadata. It does not store
headers, cookies, bearer tokens, or signed URLs. Provide an app-owned
`restorationId` and resolve fresh credentials after restart:

```dart
final request = DownloadRequest(
  url: initialUrl,
  fileName: 'invoice.pdf',
  restorationId: 'invoice:8421',
  headers: {'Authorization': 'Bearer $token'},
);

await manager.restorePending((pending) async {
  final token = await secureStorage.read(key: 'token');
  final freshUrl = await api.invoiceDownloadUrl(pending.restorationId!);
  return DownloadRequest(
    url: freshUrl,
    fileName: pending.fileName,
    restorationId: pending.restorationId,
    headers: {'Authorization': 'Bearer $token'},
    expectedSha256: pending.expectedSha256,
    validator: validateInvoice,
  );
});
```

If a refreshed response no longer matches the staged entity validators, V2
discards stale staging and restarts safely. See
[durable restoration](doc/v2-restoration.md) for details.

Validators are executable application code and are never persisted. Reattach
them in the restoration resolver, just as you supply fresh URLs and headers.

## Scope

V2 is designed for foreground Flutter transfers. It does not promise that a
download continues after the operating system terminates the app. Android and
iOS background-transfer adapters are planned as separate optional packages.

## Legacy API

The former API remains available for maintenance compatibility through a
separate entrypoint:

```dart
import 'package:resumable_downloader/resumable_downloader_legacy.dart' as legacy;
```

Legacy and V2 have independent models and managers. New integrations should use
V2; do not mix the two APIs in one transfer flow.

## Example

The included Flutter example is a developer transfer lab. It exposes session
limits, range-aware progress, speed, task controls, deletion, checksum input,
and restart restoration scenarios.

## Release Status

V2 is under active pre-release development and has not been published. Track
remaining release work in [doc/v2-publish-checklist.md](doc/v2-publish-checklist.md).
