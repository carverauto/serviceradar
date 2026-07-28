# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.5.4 (2026-05-28)
### Security
- Fix [GHSA-3rjw-m598-pq24]: `Cmov`/`CmovEq` on `aarch64` can produce wrong results if high-bits of registers are set ([dba6c355])

[GHSA-3rjw-m598-pq24]: https://github.com/RustCrypto/utils/security/advisories/GHSA-3rjw-m598-pq24
[dba6c355]: https://github.com/RustCrypto/utils/commit/dba6c355c9f241e3726d5ec2a68f9f3b519f6063

## 0.5.3 (2026-04-02)
### Added
- Impl `Cmov`/`CmovEq` for `NonZeroUsize`/`NonZeroIsize` ([#1415])

### Changed
- Avoid using `asm!` under `cfg(miri)` ([#1436])

[#1415]: https://github.com/RustCrypto/utils/pull/1415
[#1436]: https://github.com/RustCrypto/utils/pull/1436

## 0.5.2 (2026-01-20)
### Fixed
- `Cmov` impl for `isize`/`usize` ([#1412])

[#1412]: https://github.com/RustCrypto/utils/pull/1412

## 0.5.1 (2026-01-18)
### Added
- `riscv32` optimised mask generation ([#1396])
- `riscv64` optimised mask generation ([#1397])
- Support for `core::num::NonZero*` and `core::cmp::Ordering` ([#1404])

[#1396]: https://github.com/RustCrypto/utils/pull/1396
[#1397]: https://github.com/RustCrypto/utils/pull/1397
[#1404]: https://github.com/RustCrypto/utils/pull/1404

## 0.5.0 (2026-01-17)
### Added
- Optimized `CmovEq` for `[u8]` ([#1356])
- Optimized `CmovEq` for `[u16]` ([#1370])
- Impl `Cmov`/`CmovEq` for slices of unsigned integers ([#1370], [#1372])
- Impl `Cmov`/`CmovEq` for slices of signed integers ([#1373])
- Impl `Cmov`/`CmovEq` for `isize`/`usize` ([#1375])

### Changed
- Impls of `Cmov`/`CmovEq` for `[T; N]` are now bounded on `[T]: Cmov(Eq)` ([#1372])

### Removed
- Generic impl of `CmovEq` for `[T]` where `T: CmovEq` in favor of specialized impls ([#1356])

[#1356]: https://github.com/RustCrypto/utils/pull/1356
[#1370]: https://github.com/RustCrypto/utils/pull/1370
[#1372]: https://github.com/RustCrypto/utils/pull/1372
[#1373]: https://github.com/RustCrypto/utils/pull/1373
[#1375]: https://github.com/RustCrypto/utils/pull/1375

## 0.4.6 (2026-01-16)
### Added
- Optimized `Cmov` for `[u8; N]` ([#1350])
- Optimized `CmovEq` for `[u8; N]` ([#1353])
- Optimized `Cmov` for `[u8]` ([#1354])

### Fixed
- Provided `Cmov::cmovz` impl ([#1351])

[#1350]: https://github.com/RustCrypto/utils/pull/1350
[#1351]: https://github.com/RustCrypto/utils/pull/1351
[#1353]: https://github.com/RustCrypto/utils/pull/1353
[#1354]: https://github.com/RustCrypto/utils/pull/1354

## 0.4.5 (2026-01-15)
### Changed
- Introduce small ARM32 `asm!` optimization which also guarantees constant-time operation ([#1336], [#1346])

[#1336]: https://github.com/RustCrypto/utils/pull/1336
[#1346]: https://github.com/RustCrypto/utils/pull/1346

## 0.4.4 (2026-01-14)
### Security
- Fix non-constant-time assembly being emitted from portable backend on `thumbv6m-none-eabi` ([#1332])

[#1332]: https://github.com/RustCrypto/utils/pull/1332

## 0.4.3 (2025-12-27)
### Fixed
- `aarch64` ASM bug ([#1299])
- Truncation bug in portable implementation ([#1300])

[#1299]: https://github.com/RustCrypto/utils/pull/1299
[#1300]: https://github.com/RustCrypto/utils/pull/1300

## 0.4.2 (2025-12-26)
### Added
- Signed integer support ([#1280])

[#1280]: https://github.com/RustCrypto/utils/pull/1280

## 0.4.1 (2025-12-19)
### Changed
- Use `black_box` in portable impl ([#1255])

[#1255]: https://github.com/RustCrypto/utils/pull/1255

## 0.4.0 (2025-09-10)
### Changed
- Edition changed to 2024 and MSRV bumped to 1.85 ([#1149])

[#1149]: https://github.com/RustCrypto/utils/pull/1149

## 0.3.1 (2023-10-14)
### Added
- `CmovEq` impl for slices ([#954])

### Changed
- Use `#[inline]` instead of `#[inline(always)]` ([#924])
- `CmovEq` now invokes XOR within the ASM block ([#925])

[#924]: https://github.com/RustCrypto/utils/pull/924
[#925]: https://github.com/RustCrypto/utils/pull/925
[#954]: https://github.com/RustCrypto/utils/pull/954

## 0.3.0 (2023-04-02)
### Added
- `miri` support by forcing the `portable` backend ([#864])
- Constant-time equality comparisons ([#873])

### Changed
- Make `Cmov::cmovz` a provided method ([#871])

### Fixed
- Builds on `x86` (32-bit) targets ([#863])

[#863]: https://github.com/RustCrypto/utils/pull/863
[#864]: https://github.com/RustCrypto/utils/pull/864
[#871]: https://github.com/RustCrypto/utils/pull/871
[#873]: https://github.com/RustCrypto/utils/pull/873

## 0.2.0 (2023-02-26)
### Added
- `Condition` alias for `u8` ([#830])

### Changed
- Redesigned trait-based API ([#830])
  - Built around a `Cmov` trait
  - Trait is impl'd for `u8`, `u16`, `u32`, `u64`, `u128`
  - Accepts a `Condition` (i.e. `u8`) as a predicate
- MSRV 1.60 ([#839])

[#830]: https://github.com/RustCrypto/utils/pull/830
[#839]: https://github.com/RustCrypto/utils/pull/839

## 0.1.1 (2022-03-02)
### Added
- `cmovz`/`cmovnz`-alike support for AArch64 targets ([#744])

[#744]: https://github.com/RustCrypto/utils/pull/744

## 0.1.0 (2022-02-27)
- Initial release
