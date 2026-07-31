# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.4.2 (2026-04-02)
### Fixed
- `cmov` v0.5.3 version requirement ([#1467])

[#1467]: https://github.com/RustCrypto/utils/pull/1467

## 0.4.1 (2026-04-02)
### Added
- `isize`/`usize` and `NonZero*` trait impls ([#1416])
- `subtle` migration guide ([#1465])

[#1416]: https://github.com/RustCrypto/utils/pull/1416
[#1465]: https://github.com/RustCrypto/utils/pull/1465

## 0.4.0 (2026-01-19)
### Added
- `core::num::NonZero<T>` support ([#1368])
- Pluggable trait impls for `[T]` and `[T; N]` using helper traits: ([#1388])
  - `CtAssign`: `CtAssignSlice`
  - `CtEq`: `CtEqSlice`
  - `CtSelect`: `CtSelectArray`
- `CtSelectUsingCtAssign` marker trait ([#1391])

### Changed
- Split `CtAssign` out of `CtSelect` ([#1363])
- Bump `cmov` to v0.5 ([#1386])

### Removed
- `BytesCtEq`/`BytesCtSelect` no longer needed because default `[u8]` impls are fast ([#1376])
- `target_pointer_width` gating ([#1389])
- `unsafe` code ([#1405])

[#1363]: https://github.com/RustCrypto/utils/pull/1363
[#1368]: https://github.com/RustCrypto/utils/pull/1368
[#1376]: https://github.com/RustCrypto/utils/pull/1376
[#1386]: https://github.com/RustCrypto/utils/pull/1386
[#1388]: https://github.com/RustCrypto/utils/pull/1388
[#1389]: https://github.com/RustCrypto/utils/pull/1389
[#1391]: https://github.com/RustCrypto/utils/pull/1391
[#1405]: https://github.com/RustCrypto/utils/pull/1405

## 0.3.2 (2026-01-16)
### Added
- `BytesCtEq` and `BytesCtSelect` traits ([#1359])
- `CtFind` trait ([#1361])
- `CtLookup` trait ([#1362])

### Changed
- Bump `cmov` crate dependency to v0.5.0-pre.0 ([#1357])

[#1357]: https://github.com/RustCrypto/utils/pull/1357
[#1359]: https://github.com/RustCrypto/utils/pull/1359
[#1361]: https://github.com/RustCrypto/utils/pull/1361
[#1362]: https://github.com/RustCrypto/utils/pull/1362

## 0.3.1 (2026-01-03)
### Added
- `Choice::to_u8_mask`/`to_u16_mask` ([#1322])
- `Choice::select_u8`/`select_u16` ([#1324])

[#1322]: https://github.com/RustCrypto/utils/pull/1322
[#1324]: https://github.com/RustCrypto/utils/pull/1324

## 0.3.0 (2025-12-29)
### Removed
- `Choice::new` ([#1314])
- `(Partial)Eq` impls for `Choice` ([#1315])

[#1314]: https://github.com/RustCrypto/utils/pull/1314
[#1315]: https://github.com/RustCrypto/utils/pull/1315

## 0.2.3 (2025-12-29)
### Added
- Impl `From<u8>` for `Choice` ([#1309])
- `Choice::from_u8*` and `from_u16*` ([#1311])

### Changed
- Deprecate `Choice::new` ([#1312])

[#1309]: https://github.com/RustCrypto/utils/pull/1309
[#1311]: https://github.com/RustCrypto/utils/pull/1311
[#1312]: https://github.com/RustCrypto/utils/pull/1312

## 0.2.2 (2025-12-28)
### Added
- Unsigned `CtNeg` impls ([#1306])

[#1306]: https://github.com/RustCrypto/utils/pull/1306

## 0.2.1 (2025-12-27)
### Added
- Enhanced `subtle` interop ([#1289])

### Security
- Pin to `cmov` v0.4.3+ - includes important security fixes ([#1304])

[#1289]: https://github.com/RustCrypto/utils/pull/1304
[#1304]: https://github.com/RustCrypto/utils/pull/1304

## 0.2.0 (2025-12-27)
### Added
- Additional `Choice::from_u128*` constructors ([#1285])
- `CtNeg` trait ([#1286])

### Changed
- Renamed `Choice::from_*_nonzero` => `from_*_nz` ([#1287])

[#1285]: https://github.com/RustCrypto/utils/pull/1285
[#1286]: https://github.com/RustCrypto/utils/pull/1286
[#1287]: https://github.com/RustCrypto/utils/pull/1287

## 0.1.4 (2025-12-26)
### Added
- Impl `CtEq`/`CtSelect` for `isize` ([#1283])

[#1283]: https://github.com/RustCrypto/utils/pull/1283

## 0.1.3 (2025-12-26)
### Fixed
- Rustdoc syntax for variable-time-related warning text ([#1278])

[#1278]: https://github.com/RustCrypto/utils/pull/1278

## 0.1.2 (2025-12-26)
### Added
- Additional methods for `CtOption` ([#1274]):
  - `some`
  - `none`
  - `into_option_copied`
  - `filter_by`
  - `as_inner_unchecked`
  - `to_inner_unchecked`
- `Default` impl for `CtOption` ([#1274])
- `map!` and `unwrap_or!` macros ([#1274])
- `u128` methods for `Choice` ([#1277]):
  - `from_u128_le`
  - `from_u128_lsb`
  - `select_u128`

[#1274]: https://github.com/RustCrypto/utils/pull/1274
[#1277]: https://github.com/RustCrypto/utils/pull/1277

## 0.1.1 (2025-12-26)
### Added
- Additional `const fn` constructor and predication methods for `Choice` ([#1266], [#1272])

[#1266]: https://github.com/RustCrypto/utils/pull/1266
[#1272]: https://github.com/RustCrypto/utils/pull/1272

## 0.1.0 (2025-12-19)
- Initial release
