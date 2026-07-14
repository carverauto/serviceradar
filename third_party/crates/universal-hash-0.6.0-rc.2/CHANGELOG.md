# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.6.0 (UNRELEASED)
### Changed
- Edition changed to 2024 and MSRV bumped to 1.85 ([#1759])
- Migrate to `doc_auto_cfg` ([#1370])
- Exclude pre-1.60 crates from workspace ([#1380])
- bump crypto-common to v0.2.0-pre; MSRV 1.65 ([#1385])
- bump crypto-common to v0.2.0-pre.1 ([#1433])
- bump crypto-common to v0.2.0-pre.2 ([#1436])
- Bump `hybrid-array` to v0.2.0-pre.8 ([#1438])
- Bump `crypto-common` and `hybrid-array` ([#1469])
- Bump `hybrid-array` to v0.2.0-rc.4 ([#1493])
- bump crypto-common to v0.2.0-pre.5 ([#1496])

### Fixed
- Fix `missing_debug_implementations` for some crates ([#1407])

[#1370]: https://github.com/RustCrypto/traits/pull/1370
[#1380]: https://github.com/RustCrypto/traits/pull/1380
[#1385]: https://github.com/RustCrypto/traits/pull/1385
[#1407]: https://github.com/RustCrypto/traits/pull/1407
[#1433]: https://github.com/RustCrypto/traits/pull/1433
[#1436]: https://github.com/RustCrypto/traits/pull/1436
[#1438]: https://github.com/RustCrypto/traits/pull/1438
[#1469]: https://github.com/RustCrypto/traits/pull/1469
[#1493]: https://github.com/RustCrypto/traits/pull/1493
[#1496]: https://github.com/RustCrypto/traits/pull/1496
[#1759]: https://github.com/RustCrypto/traits/pull/1759

## 0.5.1 (2023-05-19)
### Changed
- Loosen `subtle` version requirement to `^2.4` ([#1260])

[#1260]: https://github.com/RustCrypto/traits/pull/1260

## 0.5.0 (2022-07-30)
### Added
- `UhfBackend` trait ([#1051], [#1059])
- `UhfClosure` trait ([#1051])
- `UniversalHash::update_with_backend` method ([#1051])

### Changed
- Replace `NewUniversalHash` trait with `KeyInit` from `crypto-common` ([#1051])
- Source `Block` and `Key` types from `crypto-common` ([#1051])
- `UniversalHash::update` is now provided takes a slice of blocks ([#1051])
- `UniversalHash::finalize` now returns a `Block` ([#1051])
- Rust 2021 edition; MSRV 1.56 ([#1051])

### Removed
- `Output` replaced by `Block` ([#1051])
- `UniversalHash::reset` replaced with `Reset` trait from `crypto-common` ([#1051])

[#1051]: https://github.com/RustCrypto/traits/pull/1051
[#1059]: https://github.com/RustCrypto/traits/pull/1059

## 0.4.1 (2021-07-20)
### Changed
- Pin `subtle` dependency to v2.4 ([#689])

[#689]: https://github.com/RustCrypto/traits/pull/689

## 0.4.0 (2020-06-04)
### Added
- `Key` and `Block` type aliases ([#128])

### Changed
- Split `UniversalHash` initialization into `NewUniversalHash` trait ([#135])
- Rename `update_block` => `update` ([#129])
- Bump `generic-array` dependency to v0.14 ([#95])

[#135]: https://github.com/RustCrypto/traits/pull/135
[#129]: https://github.com/RustCrypto/traits/pull/129
[#128]: https://github.com/RustCrypto/traits/pull/128
[#95]: https://github.com/RustCrypto/traits/pull/95

## 0.3.0 (2019-10-03)
- Rename `OutputSize` -> `BlockSize` ([#57])

[#57]: https://github.com/RustCrypto/traits/pull/57

## 0.2.0 (2019-08-31)
### Changed
- Split KeySize/OutputSize ([#55])

[#55]: https://github.com/RustCrypto/traits/pull/55

## 0.1.0 (2019-08-30)
- Initial release
