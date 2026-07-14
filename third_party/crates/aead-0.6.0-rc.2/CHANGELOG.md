# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased
### Fixed
- minor documentation error in `AeadCore::TagSize` ([#1351])
- fixup `hybrid-array` migration ([#1531])

### Changed
- Edition changed to 2024 and MSRV bumped to 1.85 ([#1759])
- Migrate to `doc_auto_cfg` ([#1370])
- Exclude pre-1.60 crates from workspace ([#1380])
- bump `crypto-common` to v0.2.0-pre; MSRV 1.65 ([#1384])
- Bump `heapless` dependency to v0.8 ([#1398])
- Bump `hybrid-array` to v0.2.0-pre.6 ([#1432])
- Bump `crypto-common` to v0.2.0-pre.1 ([#1433])
- Bump `crypto-common` to v0.2.0-pre.2 ([#1436])
- Bump `hybrid-array` to v0.2.0-pre.8 ([#1438])
- Bump `crypto-common` and `hybrid-array` ([#1469])
- Bump `crypto-common` to v0.2.0-pre.5 ([#1496])

### Added
- enable `missing_debug_implementations` lint and add `Debug` impls ([#1411])


[#1351]: https://github.com/RustCrypto/traits/pull/1351
[#1370]: https://github.com/RustCrypto/traits/pull/1370
[#1380]: https://github.com/RustCrypto/traits/pull/1380
[#1384]: https://github.com/RustCrypto/traits/pull/1384
[#1398]: https://github.com/RustCrypto/traits/pull/1398
[#1411]: https://github.com/RustCrypto/traits/pull/1411
[#1432]: https://github.com/RustCrypto/traits/pull/1432
[#1433]: https://github.com/RustCrypto/traits/pull/1433
[#1436]: https://github.com/RustCrypto/traits/pull/1436
[#1438]: https://github.com/RustCrypto/traits/pull/1438
[#1469]: https://github.com/RustCrypto/traits/pull/1469
[#1496]: https://github.com/RustCrypto/traits/pull/1496
[#1531]: https://github.com/RustCrypto/traits/pull/1531
[#1759]: https://github.com/RustCrypto/traits/pull/1759

## 0.5.2 (2023-04-02)
### Added
- `arrayvec` feature ([#1219])

[#1219]: https://github.com/RustCrypto/traits/pull/1219

## 0.5.1 (2022-08-09)
### Added
- `AeadCore::generate_nonce` ([#1073])

[#1073]: https://github.com/RustCrypto/traits/pull/1073

## 0.5.0 (2022-07-23)
### Added
- Optional support for `BytesMut` as a `Buffer` ([#956])
- `getrandom` feature ([#1042])

### Changed
- Replace `NewAead` trait with `KeyInit` trait from `crypto-common` ([#1033])
- Rust 2021 edition upgrade; MSRV 1.56+ ([#1044])

[#956]: https://github.com/RustCrypto/traits/pull/956
[#1033]: https://github.com/RustCrypto/traits/pull/1033
[#1042]: https://github.com/RustCrypto/traits/pull/1042
[#1044]: https://github.com/RustCrypto/traits/pull/1044

## 0.4.3 (2021-08-29)
### Added
- `Result` type alias ([#725])

[#725]: https://github.com/RustCrypto/traits/pull/725

## 0.4.2 (2021-07-12)
### Added
- Re-export `rand_core` ([#682])

[#682]: https://github.com/RustCrypto/traits/pull/682

## 0.4.1 (2021-05-03)
### Changed
- Bump `heapless` dependency to v0.7 ([#628])

[#628]: https://github.com/RustCrypto/traits/pull/628

## 0.4.0 (2021-02-05) [YANKED]
### Added
- `stream` module ([#436], [#445], [#447])
- `NewAead::generate_key` method gated under `rand_core` feature ([#513])

### Changed
- Extract `AeadCore` trait ([#508])
- Rename `NewAead::new_var` to `::new_from_slice` ([#512])
- Disable alloc by default ([#514])
- Bump `heapless` dependency to v0.6 ([#522])

[#436]: https://github.com/RustCrypto/traits/pull/436
[#445]: https://github.com/RustCrypto/traits/pull/445
[#447]: https://github.com/RustCrypto/traits/pull/447
[#508]: https://github.com/RustCrypto/traits/pull/508
[#512]: https://github.com/RustCrypto/traits/pull/512
[#513]: https://github.com/RustCrypto/traits/pull/513
[#514]: https://github.com/RustCrypto/traits/pull/514
[#522]: https://github.com/RustCrypto/traits/pull/522

## 0.3.2 (2020-07-01)
### Added
- `dev` module ([#194])

[#194]: https://github.com/RustCrypto/traits/pull/194

## 0.3.1 (2020-06-12)
### Added
- `NewAead::new_varkey` method ([#191])

[#191]: https://github.com/RustCrypto/traits/pull/191

## 0.3.0 (2020-06-04)
### Added
- Type aliases for `Key`, `Nonce`, and `Tag` ([#125])
- Optional `std` feature ([#63])

### Changed
- `NewAead` now borrows the key ([#124])
- Split `Aead`/`AeadMut` into `AeadInPlace`/`AeadMutInPlace` ([#120])
- Bump `generic-array` dependency to v0.14 ([#95])

[#125]: https://github.com/RustCrypto/traits/pull/125
[#124]: https://github.com/RustCrypto/traits/pull/124
[#120]: https://github.com/RustCrypto/traits/pull/120
[#95]: https://github.com/RustCrypto/traits/pull/95
[#63]: https://github.com/RustCrypto/traits/pull/63

## 0.2.0 (2019-11-17)

## 0.1.2 (2019-11-17) [YANKED]

## 0.1.1 (2019-08-30)

## 0.1.0 (2019-08-29)
