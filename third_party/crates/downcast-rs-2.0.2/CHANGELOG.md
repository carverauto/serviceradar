# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

## 2.0.2 - 2025-09-01

### Changed
- Updated `README.md` to omit lines hidden in crate documentation.
- (Minor) `Cargo.toml`: Corrected license format and added categories.

## 2.0.1 - 2025-01-06

### Change
- Updated how code conditioned on the `sync` flag is written in the crate
  documentation to work around a [crates.io doc rendering
  bug](https://github.com/rust-lang/crates.io/issues/10331).

## 2.0.0 - 2025-01-06
### Added
- Gated the sync/`Arc` downcasting functionality behind a new `sync` feature
  that is enabled by default.
- Added a new `DowncastSend` trait to support downcasting to `Box<Any + Send>`
  and made `DowncastSync` extend this trait.
- Added downcasting support to `Box<Any + Send + Sync>` to `DowncastSync`.

### Change
- Updated minimum supported rust version 1.56 to enforce the
  `rustdoc::bare_urls` lint (1.53) and switch to edition 2021 (1.56).

## 1.2.1 - 2024-04-06
### Change
- Consolidated bounds on the trait to avoid triggering Clippy's
  `multiple_bound_locations` lint.

## 1.2.0 - 2020-06-29
### Added
- `no_std` support.
- CI with GitHub actions.

### Changed
- Updated minimum supported rust version 1.36 for stable access to `alloc`.

## 1.1.1 - 2019-10-28
### Changed
- Used `dyn Trait` syntax everywhere since it is supported by downcast-rs's
  min-supported rust version (1.33).

## 1.1.0 - 2019-10-07
### Added
- Support for downcasting `Rc<Trait>` and `Arc<Trait>`.

### Changed
- Minimum supported Rust version upped to 1.33 to support `Rc` and `Arc` in the
  receiver position.

## 1.0.4 - 2019-04-08
### Changed
- Added `local_inner_macros` to `impl_downcast` to allow invoking via namespace.

## 1.0.3 - 2018-05-21
### Fixed
- Use global path for Result, Option, Box in macro expansion to avoid name
  conflicts with locally-defined symbols.

## 1.0.2 - 2018-05-12
### Added
- Support for downcasting `Box<Trait>` to `Box<Concrete>`.

## 1.0.1 - 2018-03-08
### Fixed
- Don't use types as traits in macros.

## 1.0.0 - 2017-02-05
### Changed
- Cleaned up README and published 1.0.

## 0.1.2 - 2016-11-22
### Added
- Support for associated types as well.

## 0.1.1 - 2016-09-04
### Added
- Downcast functionality to downcast borrowed mutable and immutable trait
  objects to concrete types. Supports concrete type parameters and type
  variables with optional constraints.

