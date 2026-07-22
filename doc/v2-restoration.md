# V2 Durable Restoration

V2 stores partial bytes and a manifest under `.resumable_downloader_v2` beside
the destination directory. The manifest contains transfer checkpoints and
non-sensitive identity metadata only. It never stores request headers, bearer
tokens, cookies, or other credentials.

Use a stable app-owned `restorationId` for downloads that require refreshed
authentication or signed URLs:

```dart
final request = DownloadRequest(
  url: initialUrl,
  fileName: 'invoice.pdf',
  restorationId: 'invoice:8421',
  headers: {'Authorization': 'Bearer $token'},
);
```

After an app restart, discover and resume pending transfers through a resolver:

```dart
final tasks = await manager.restorePending((pending) async {
  final token = await secureStorage.read(key: 'access-token');
  final url = await api.invoiceUrl(pending.restorationId!);

  return DownloadRequest(
    url: url,
    fileName: pending.fileName,
    restorationId: pending.restorationId,
    headers: {'Authorization': 'Bearer $token'},
    expectedSha256: pending.expectedSha256,
  );
});
```

The resolver may provide a changed URL. V2 resumes staged bytes only when the
server validators and range plan remain compatible; otherwise it discards the
staging data and restarts safely. Returning `null` skips a pending transfer.

## Manifest Compatibility

Transfer manifests are an internal V2 persistence format. A newer V2 release
may reject an older or malformed manifest and restart that transfer from zero;
applications must treat the final output file, not the staged manifest, as the
durable artifact. Never create or modify manifest files outside this package.
