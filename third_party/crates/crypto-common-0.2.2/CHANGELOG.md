# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.2.2 (2026-05-19)
### Added
- `SetIvState` trait ([#2420])

[#2420]: https://github.com/RustCrypto/traits/pull/2420

## 0.2.1 (2026-02-25)
### Changed
- `BlockSizeUser::BlockSize` is no longer bounded by `BlockSizes` ([#2309])

### Removed
- `BlockSizes` trait ([#2309])

[#2309]: https://github.com/RustCrypto/traits/pull/2309

## 0.2.0 (2026-02-04) [YANKED]
Note: this version was yanked because v0.2.1 introduces breaking changes.
Users should migrate to v0.2.1 using `cargo update`.

### Added
- Sealed `BlockSizes` trait implemented for types from `U1` to `U255` ([#1172])
- `SerializableState` trait under `hazmat` module ([#1369])
- `OutputSize` type alias ([#1533])
- `IvState` trait ([#1636])
- `core::error::Error` impls for error types ([#1660])
- `Generate` trait as a common RNG API ([#2096], [#2145])
- `TryKeyInit` trait ([#2097])
- Re-export `getrandom` ([#2152])
- `KeyExport` trait ([#2213])

### Changed
- Replaced `generic-array` with `hybrid-array` ([#1319], [#1976])
- `BlockUser::BlockSize` is now bounded by the `BlockSizes` trait
- Edition changed to 2024 and MSRV bumped to 1.85 ([#1759])
- `generate_*` methods on `KeyInit` and `KeyIvInit` traits have been deprecated in favor of the
  new `Generate` trait ([#2162])
- Bump `rand_core` to v0.10 ([#2250])
- Bump `getrandom` to v0.4 ([#2258])

### Removed
- `std` feature ([#1680])

[#1172]: https://github.com/RustCrypto/traits/pull/1172
[#1319]: https://github.com/RustCrypto/traits/pull/1319
[#1369]: https://github.com/RustCrypto/traits/pull/1369
[#1533]: https://github.com/RustCrypto/traits/pull/1533
[#1636]: https://github.com/RustCrypto/traits/pull/1636
[#1660]: https://github.com/RustCrypto/traits/pull/1660
[#1680]: https://github.com/RustCrypto/traits/pull/1680
[#1759]: https://github.com/RustCrypto/traits/pull/1759
[#1976]: https://github.com/RustCrypto/traits/pull/1976
[#2096]: https://github.com/RustCrypto/traits/pull/2096
[#2097]: https://github.com/RustCrypto/traits/pull/2097
[#2145]: https://github.com/RustCrypto/traits/pull/2145
[#2152]: https://github.com/RustCrypto/traits/pull/2152
[#2162]: https://github.com/RustCrypto/traits/pull/2162
[#2213]: https://github.com/RustCrypto/traits/pull/2213
[#2250]: https://github.com/RustCrypto/traits/pull/2250
[#2258]: https://github.com/RustCrypto/traits/pull/2258

## 0.1.7 (2025-11-12)
### Changed
- Pin `generic-array` to v0.14.7 ([#2088])

[#2088]: https://github.com/RustCrypto/traits/pull/2088

## 0.1.6 (2022-07-16)
### Added
- Move `ParBlocks`/`ParBlocksSizeUser` from `cipher` crate ([#1052])

[#1052]: https://github.com/RustCrypto/traits/pull/1052

## 0.1.5 (2022-07-09)
### Fixed
- Support on-label MSRV ([#1049])

[#1049]: https://github.com/RustCrypto/traits/pull/1049

## 0.1.4 (2022-07-02)
### Added
- `getrandom` feature ([#1034])

[#1034]: https://github.com/RustCrypto/traits/pull/1034

## 0.1.3 (2022-02-16)
### Fixed
- Minimal versions build ([#940])

[#940]: https://github.com/RustCrypto/traits/pull/940

## 0.1.2 (2022-02-10)
### Added
- Re-export `generic-array` and `typenum`. Enable `more_lengths` feature on
`generic-array`.  Add `key_size`, `iv_size`, `block_size`, and `output_size`
helper methods. ([#849])

[#849]: https://github.com/RustCrypto/traits/pull/849

## 0.1.1 (2021-12-14)
### Added
- `rand_core` re-export and proper exposure of key/IV generation methods on docs.rs ([#847])

[#847]: https://github.com/RustCrypto/traits/pull/847

## 0.1.0 (2021-12-07)
- Initial release
