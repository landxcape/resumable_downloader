# Multipart Transfer Engine Design

## Goal

Replace the current downloader with a robust, Flutter-first native download API.
The new API supports fair parallel downloads across files and byte ranges within a
single eligible file. It is designed for Android, iOS, macOS, Windows, and Linux.

The existing API remains available through a separate legacy library entry point.
The root library is a deliberate API redesign with no compatibility wrapper or
shared public types from the current implementation.

## Scope

The first release provides:

- Native local-file downloads using Dio.
- A bounded queue of file transfers.
- Automatic, verified multipart downloads for eligible files.
- A global HTTP-connection budget shared fairly between files and their ranges.
- Retry, cancellation, resumable partial files, and safe finalization.
- Per-task and manager-wide lifecycle updates.
- A local HTTP-server test suite covering success and failure modes.
- A migration guide and a separate legacy entry point.

The first release does not provide:

- Browser support.
- OS background execution.
- Automatic restoration of queued tasks after an app restart.
- Pause/resume controls, speed limits, ETA, or persistent history.
- Checksums supplied by remote metadata. HTTP range and length validation is
  required, but cryptographic content validation is deferred.

## Package Surface

The root package entry point, `package:resumable_downloader/resumable_downloader.dart`,
exports the new API only. It includes these public concepts:

```dart
final manager = DownloadManager(
  subdirectory: 'downloads',
  configuration: const DownloadConfiguration(
    maxConcurrentDownloads: 3,
    maxConcurrentConnections: 6,
    maxConnectionsPerDownload: 4,
  ),
);

final task = manager.enqueue(
  DownloadRequest(
    url: url,
    fileName: 'video.mp4',
    headers: headers,
  ),
);

task.updates.listen(handleUpdate);
final file = await task.result;
```

`DownloadManager.download(request)` is a convenience method that enqueues a task
and returns its result. `enqueueAll`, `cancel`, `cancelAll`, and `dispose` are
provided where they have clear task-oriented semantics.

`DownloadTask` owns a stable generated task ID, a `Future<File>` result, a stream
of `DownloadUpdate` values, and cancellation. `DownloadUpdate` reports state,
bytes received, total bytes when known, completed and active range counts, retry
attempt, final path, and error information. The lifecycle states are `queued`,
`preparing`, `downloading`, `retrying`, `completed`, `failed`, and `cancelled`.

`DownloadUpdate` also includes an immutable list of `DownloadRangeUpdate` values.
Each range update contains inclusive start and end byte offsets, bytes received,
and its transfer state. V2 emits one range snapshot for single-stream files and
one snapshot per planned range for multipart files. Aggregate task progress and
range snapshots are emitted together at a bounded cadence so user interfaces can
render actual range activity without deriving it from counts.

`DownloadConfiguration` defaults to three active files, six total connections,
four connections per eligible file, and an 8 MiB minimum byte range. A file must
therefore be at least 16 MiB before V2 considers using two ranges. Configuration
is immutable once a manager is created.

`DownloadRequest` contains the source URL, optional filename, optional
subdirectory, request headers, and file-existence behavior. Per-request multipart
overrides are deferred; manager configuration is the sole control in this release.
Its V2 `ExistingFilePolicy` type is independent from the legacy enum.

## Legacy Surface

The existing implementation is kept intact under `src/legacy/` and is exposed by:

```dart
import 'package:resumable_downloader/resumable_downloader_legacy.dart' as legacy;

final manager = legacy.DownloadManager(subDir: 'downloads');
final file = await manager.getFile(url);
```

The legacy library is documented as maintenance-only. It receives critical fixes,
but no new features. Its classes and methods are preserved there exactly; V2 does
not support, export, or adapt them. The old and new implementations never share
live queues, cancellation state, partial files, resume manifests, or public models.

## Internal Architecture

```text
DownloadManager
  -> TransferScheduler
       -> TransferCoordinator (one file)
            -> TransferProbe
            -> TransferPlan
            -> RangeWorker (one request per range)
            -> TransferStorage
                 -> FileTransferStorage
                 -> ManifestStore
  -> TransferHttpClient
       -> DioTransferHttpClient
```

`TransferScheduler` owns file admission, the global connection budget, and fair
connection allocation. It gives eligible queued files their first connection
before allocating spare slots to extra ranges. It never exceeds
`maxConcurrentDownloads`, `maxConcurrentConnections`, or
`maxConnectionsPerDownload`.

`TransferCoordinator` owns exactly one file transfer. It probes the server,
chooses a transfer plan, aggregates range progress, applies retry policy, and
publishes task state. It has no direct filesystem or Dio dependency.

`TransferProbe` uses a metadata request and, when needed, a small range request to
verify content length and range behavior. A range response must return `206 Partial
Content` with a matching `Content-Range`; `Accept-Ranges` alone is not trusted.

`TransferPlan` uses one stream when content length is unknown, ranges are not
verified, or the file is below the multipart threshold. Otherwise it divides the
file into non-overlapping ranges no smaller than the configured minimum.

`RangeWorker` owns one HTTP stream, one cancellation token, one independent file
handle, and its retry loop. It writes only within its assigned offsets. A parent
task cancellation cancels every active worker. It reports received-byte changes to
its coordinator, which updates the matching `DownloadRangeUpdate` and aggregate
task progress.

`TransferStorage` owns file paths, preallocation, independent offset writes,
finalization, cleanup, and a versioned sidecar manifest. The manifest records a
transfer key, URL, effective output path, total length, validators, range progress,
and format version. V2 uses its own temp and manifest names, never the legacy
`.tmp` path.

`TransferHttpClient` is a small internal interface used by probes and range
workers. `DioTransferHttpClient` is the production implementation. The transport
returns streaming responses and validated metadata; the engine does not use
`Dio.download()`.

## Correctness Rules

- A task key includes more than URL: destination, request identity, and relevant
  headers distinguish independent work.
- A changed `ETag` or `Last-Modified` invalidates a partial manifest and starts a
  new transfer safely.
- A range request that receives `200 OK`, an invalid `Content-Range`, an
  inconsistent length, or a changed validator cannot append to existing partial
  content. The task falls back safely or restarts according to its plan.
- A completed download is atomically moved into its final path only after every
  range is complete and the assembled length matches the verified total.
- Cancellation always reaches a terminal task state, closes update streams, and
  leaves or removes partial data according to the configured resumability policy.
- There is no independent Google or ping connectivity preflight. The actual probe
  and download request determine connectivity and errors.
- Unknown content length remains explicitly unknown. It never becomes 100% progress.

## Failure Handling

The new API publishes typed `DownloadException` failures, with categories for
network, timeout, server protocol, storage, cancellation, and unexpected errors.
The original cause remains available for diagnostics. Retry applies only to
transient failures, is bounded by configuration, and uses exponential backoff with
jitter. Cancellation and protocol-validation failures are not retried blindly.

## Test Strategy

Tests use an in-process `HttpServer` and temporary directories. Required scenarios:

- Single-stream success, unknown-size stream, and normal finalization.
- Verified multipart assembly and byte-for-byte output equality.
- Multiple files plus multipart ranges observing global and per-file limits.
- Fair slot allocation when large and small files compete.
- Range rejection, malformed content ranges, redirects, and changing validators.
- Mid-stream disconnects, transient retries, non-retryable failures, and cleanup.
- Cancellation during probe, single-stream transfer, and multipart transfer.
- Resume from valid manifest and restart from invalid or stale manifest.
- File-existence behavior, task identity, status sequence, disposal, and errors.

`dart analyze`, formatter checks, unit tests, and the example application must all
pass before publishing.

## Delivery Plan

1. Preserve the current implementation in the legacy library and add isolated test
   infrastructure with a local HTTP server.
2. Define the new public models and task/status lifecycle tests.
3. Implement storage, manifests, transport probe, and single-stream V2 transfers.
4. Add the scheduler, strict connection leases, and multipart range workers.
5. Add resume validation, retries, cancellation, and competing-transfer tests.
6. Update documentation, example application, changelog, and migration guide.
7. Publish `0.1.0` after release-gate verification.

## Migration Direction

Users choose either the new root entry point or the legacy entry point. Migration
is explicit rather than behavioral: `QueueItem` becomes
`DownloadRequest`; `getFile` and progress callbacks become a `DownloadTask` with
`result` and `updates`; manager-level settings move into
`DownloadConfiguration`.

## Deferred Advanced Modes

The V2 core is intentionally shaped so persistent queue recovery, pause/resume,
background platform adapters, speed limits, checksums, and richer telemetry can be
added later without rewriting scheduler, transfer, or storage boundaries.
