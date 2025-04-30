# Changelog

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
