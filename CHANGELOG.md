# Changelog

## [0.0.30] - 2025-07-29

- Updated sub directory logic to handle individual values assigned to [QueueItem].

## [0.0.29] - 2025-07-28

- Removed redundent last progress update logic.

## [0.0.28] - 2025-07-27

- Fixed using [subDirectory] to get local path properly

## [0.0.27] - 2025-07-27

- Fixed passing [subDirectory] in [QueueItem]

## [0.0.26] - 2025-07-25

- Add a method to delete directory from the [baseDirectory]

## [0.0.25] - 2025-07-21

- Fixed file download progress stream closure.

## [0.0.24] - 2025-07-17

- Update file path handling check.

## [0.0.23] - 2025-07-17

- Add [getFile] item to the front of the queue.

## [0.0.22] - 2025-07-16

- Fixed [subDir] local path formating issue.

## [0.0.21] - 2025-07-16

- Fixed [onComplete] null check error

## [0.0.20] - 2025-07-16

- Added [subDir] and [onComplete] callback to queue item.

## [0.0.19] - 2025-07-07

- Fixed queue not processing on the lastest update

## [0.0.18] - 2025-06-30

- Enable deleteOnError based on fileExistsStrategy: Sets the deleteOnError parameter to true unless the fileExistsStrategy is set to resume, ensuring partial files are deleted on errors except when resuming downloads.

## [0.0.17] - 2025-06-01

- fixed file rename issue

## [0.0.16] - 2025-05-28

- fixed [FileStorageStetragy.resume] resume behavior when a custom name is provided.

## [0.0.15] - 2025-05-21

- optimized [QueueItem]'s progress callback to return [DownloadProgress] directly instead of a [Stream]. It was sending full stream on each callback instead of sending it at the first once. This was done to simplify callback to only return [DownloadProgress] and handle the stream internally.

## [0.0.14] - 2025-05-21

- add initial file [DownloadProgress] status to progress stream before download

## [0.0.13] - 2025-05-21

- fix [FileStorageStetragy.resume] not working as expected

## [0.0.12] - 2025-05-19

- fix [tempFile] name to match with custom name in [QueueItem]

## [0.0.11] - 2025-05-19

- fix [DownloadProgress] last receive bytes data

## [0.0.10] - 2025-05-18

- add more info on [DownloadProgress], receivedBytes and totalBytes along with progress

## [0.0.9] - 2025-05-16

- add optional [fileName] added to [QueueItem]

## [0.0.8] - 2025-05-02

- updated readme to reflect latest changes

## [0.0.7] - 2025-05-02

- Replaced dart ***records*** with ***class*** implementation
- Added proper file bytes validation if the file already exists.

## [0.0.6] - 2025-04-30

- Update README and example: add dispose()

## [0.0.5] - 2025-04-30

- Refactor formating

## [0.0.4] - 2025-04-30

- Update homepage

## [0.0.3] - 2025-04-30

- New feature: added support for delay before attempting retry

## [0.0.2] - 2025-04-30

### Fixed

- Bug fix: Some typo

## [0.0.1] - 2025-04-30

### Added

- Initial release of the `resumable_downloader` package.
- Support for resumable downloads using HTTP `Range` headers.
- Concurrent and queued download handling.
- File existence strategies (`keepExisting`, `resume`, `replace`, `fail`).
- Download progress updates and cancelation support.
- Full control over downloads using `Dio`, custom directory setup, and retry handling.
