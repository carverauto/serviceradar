# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Added
- N/A

### Changed
- Moved the `futures` dependency to `dev-dependencies`. MSRV is now 1.48.

### Deprecated
- N/A

### Removed
- N/A

### Fixed
- N/A

### Security
- N/A

## [0.5.2] - 2025-06-23

### Changed
- Moved the `futures` dependency to `dev-dependencies`
- MSRV is now 1.48. Since we don't have a stated MSRV policy and 1.48 is almost older than this
crate, much less version `0.5.0`, I am fine with doing this in a patch release.

## [0.5.1] - 2023-08-23
### Fixed
- Use `saturating_mul` instead of `Mul` ([#27])

[#27]: https://github.com/EmbarkStudios/tryhard/pull/27

## [0.5.0] - 2022-09-01
### Changed
- Move to `pin-project-lite` instead of `pin-project` ([#21](https://github.com/EmbarkStudios/tryhard/pull/21))
- `RetryFuture::on_retry` has additional type parameter and trait bound ([#22])

### Fixed
- Fixed inference issues with `RetryFuture::on_retry` ([#22])

[#22]: https://github.com/EmbarkStudios/tryhard/pull/22

## [0.4.0] - 2021-06-22
### Added
- `BackoffStrategy` is now implemented directly for functions of the right type.
- Explicit constructs have been added to each back-off strategy. This makes it
  possible to define a new strategy that wraps one of the types provided by
  tryhard.

### Changed
- `BackoffStrategy` is now generic over the lifetime of the error given to
  `BackoffStrategy::delay`.
- The output of the future returned by `OnRetry::on_retry` has been
  fixed to `()`. As the future is given to `tokio::spawn` requiring `()` is
  nicer.

### Deprecated
- N/A

### Removed
- `CustomBackoffStrategy` has been removed since `BackoffStrategy` is now
  implemented directly on functions of the right type.
- Tokio 0.2 support has been removed. Tokio 1 is now the only version
  supported.

### Fixed
- `RetryFuture` no longer requires the error type to implement `Display`.

### Security
- N/A

## [0.3.0] - 2021-01-07
### Added
- Support for Tokio 1.0 added. Tokio 1.0 support is on by default or by enabling the `tokio-1` feature.
- Add `RetryFutureConfig` which let you retry several futures in the same way.
- All backoff strategy types now implement `Copy` and `Clone`.

### Removed
- Support for Tokio 0.3 has been removed. 0.2 is still supported.

### Fixed
- `CustomBackoffStrategy` now implements `Debug` regardless of its type parameter.

## [0.2.0] - 2020-11-25
### Changed
- Changed from using Tokio 0.2 by default to using Tokio 0.3. You can switch back to Tokio 0.2 by declaring your dependency with `tryhard = { version = "your-version", default-features = false, features = ["tokio-02"] }`.

## [0.1.0] - 2020-11-21
### Added
- First release!

[Unreleased]: https://github.com/EmbarkStudios/tryhard/compare/0.5.2...HEAD
[0.5.2]: https://github.com/EmbarkStudios/tryhard/compare/0.5.1...0.5.2
[0.5.1]: https://github.com/EmbarkStudios/tryhard/compare/0.5.0...0.5.1
[0.5.0]: https://github.com/EmbarkStudios/tryhard/compare/0.4.0...0.5.0
[0.4.0]: https://github.com/EmbarkStudios/tryhard/compare/0.3.0...0.4.0
[0.3.0]: https://github.com/EmbarkStudios/tryhard/compare/0.2.0...0.3.0
[0.2.0]: https://github.com/EmbarkStudios/tryhard/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/EmbarkStudios/tryhard/releases/tag/0.1.0
