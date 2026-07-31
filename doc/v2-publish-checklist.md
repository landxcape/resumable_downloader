# V2 Stable Release Checklist

Release target: stable `0.1.0` foreground Flutter download manager with durable
restoration.
Android and iOS background adapters are explicitly out of scope for this
release.

## Core Behavior

- [ ] Validate multipart downloads against at least two public range-capable servers.
- [ ] Validate single-stream fallback against a server that ignores `Range`.
- [ ] Validate pause, resume, cancel, delete, and replace on a physical Android device.
- [ ] Validate app-restart restoration of a partial transfer.
- [ ] Validate authenticated restoration with a fresh token or signed URL.
- [ ] Validate changed `ETag` or `Last-Modified` restarts rather than reuses stale bytes.
- [ ] Validate expected SHA-256 success and mismatch behavior.
- [x] Validate concurrent files plus multipart ranges under configured scheduler limits.

## Recovery And Storage

- [x] Cover corrupted manifest JSON and truncated partial-file recovery.
- [ ] Cover unavailable or read-only destination-directory failures.
- [ ] Cover duplicate enqueue, delete while active, and delete after completion.
- [x] Confirm manifests never contain headers, cookies, tokens, or signed URL credentials.
- [x] Decide and document manifest compatibility expectations for future V2 releases.

## API And Documentation

- [x] Replace root README legacy usage with V2-first documentation.
- [x] Document the separate `legacy` entrypoint and migration boundary.
- [x] Document configuration limits, range fallback, retry policy, and output policies.
- [x] Document `DownloadTask` lifecycle updates and pause/resume behavior.
- [x] Link the secure restoration guide: `doc/v2-restoration.md`.
- [x] Add concise API examples for multipart, checksum, deletion, and restoration.
- [x] Confirm public exports expose every intended V2 API and no internal types.

## Example Lab

- [ ] Test the example on Android with all presets and a manual URL.
- [ ] Confirm speed, part counts, retry/error detail, and output path remain readable.
- [ ] Confirm active and completed deletion behave correctly.
- [ ] Confirm edited session configuration starts a new manager session.
- [ ] Add a clearly labeled authenticated-restoration resolver example without secrets.

## Release Quality

- [ ] Run `dart format --output=none --set-exit-if-changed .`.
- [x] Run `dart analyze` with no warnings or infos.
- [x] Run the package test suite serially and investigate any flakes.
- [x] Run `flutter pub publish --dry-run`.
- [x] Review `pubspec.yaml`: description, homepage, repository, topics, SDK constraints, and version.
- [x] Update `CHANGELOG.md` with V2 scope, breaking changes, and legacy availability.
- [x] Choose the stable release version: `0.1.0`.
- [x] Review the final diff and commit only source, tests, docs, and intentional example changes.

The stable release is published. Remaining unchecked items are follow-up
validation or enhancement work and do not block the foreground V2 release.

## Deferred After Publish

- [ ] Android foreground-service or user-initiated-transfer adapter.
- [ ] iOS `URLSession` background-download adapter.
- [ ] Batch restoration policy and app-specific network constraints.
- [ ] Optional richer telemetry such as per-part speed and protocol diagnostics.
