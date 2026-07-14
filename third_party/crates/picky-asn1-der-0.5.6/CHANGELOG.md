# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).


## [[0.5.6](https://github.com/Devolutions/picky-rs/compare/picky-asn1-der-v0.5.5...picky-asn1-der-v0.5.6)] - 2026-04-21

### <!-- 7 -->Build

- Upgrade RustCrypto dependencies ([#476](https://github.com/Devolutions/picky-rs/issues/476)) ([8ce838e347](https://github.com/Devolutions/picky-rs/commit/8ce838e3470ac605c912f61dc67c1c6d388b140d)) 

## [[0.5.5](https://github.com/Devolutions/picky-rs/compare/picky-asn1-der-v0.5.4...picky-asn1-der-v0.5.5)] - 2026-02-02

### <!-- 7 -->Build

- Update crypto dependencies ([#448](https://github.com/Devolutions/picky-rs/issues/448)) ([0bf42c1c4b](https://github.com/Devolutions/picky-rs/commit/0bf42c1c4bd727eaf5b4b0a877e8698986e0bd37)) 


## [[0.5.4](https://github.com/Devolutions/picky-rs/compare/picky-asn1-der-v0.5.3...picky-asn1-der-v0.5.4)] - 2025-10-21

### <!-- 7 -->Build

- Remove lazy_static ([#424](https://github.com/Devolutions/picky-rs/issues/424)) ([d96e761fba](https://github.com/Devolutions/picky-rs/commit/d96e761fbaf7e4061a9488240e3f6426a53cc6b1)) 

### Changed

- Bump minimal rustc version to 1.85.

## [[0.5.3](https://github.com/Devolutions/picky-rs/compare/picky-asn1-der-v0.5.2...picky-asn1-der-v0.5.3)] - 2025-09-26

### <!-- 7 -->Build

- Bump the crypto group across 1 directory with 3 updates (#388) ([58d179a0c3](https://github.com/Devolutions/picky-rs/commit/58d179a0c39d701025a363c3f294912c2881a8f5)) 

## [[0.5.2](https://github.com/Devolutions/picky-rs/compare/picky-asn1-der-v0.5.1...picky-asn1-der-v0.5.2)] - 2025-01-16

### <!-- 4 -->Bug Fixes

- Symlinks to license files in packages (#339) ([1834c04f39](https://github.com/Devolutions/picky-rs/commit/1834c04f3930fb1bbf040deb6525b166e378b8aa)) 

  Use symlinks instead of copying files to avoid a “dirty” state during
  cargo publish and preserve VCS info. With #337 merged, CI handles
  publishing consistently, so developer environments no longer matter.

## [0.5.1] 2024-11-26

### Changed

- Update dependencies

## [0.5.0] 2024-07-12

### Changed

- Bump minimal rustc version to 1.61
- Update dependencies

## [0.4.1] 2023-08-23

### Fixed

- License files are now correctly included in the published package

### Changed

- Update dependencies

## [0.4.0] 2022-11-07

### Added

- Derive additional traits for some types ([#171](https://github.com/Devolutions/picky-rs/pull/171))

## [0.3.1] 2022-05-19

### Changed

- Make `ApplicationTag`’s inner value public
- Update dependencies

## [0.3.0] 2022-02-02

### Added

- Support for `GeneralString`
- `ApplicationTag` to encode ASN.1 application tags

### Changed

- Bump minimal rustc version to 1.56

## [0.2.5] 2021-05-27

### Added

- Support for `BMP_STRING` type

## [0.2.4] 2020-08-31

### Changed

- Update dependencies

## [0.2.3] 2020-07-07

### Changed

- Dependencies clean up

## [0.2.2] 2020-01-14

### Fixed

- Fix `Asn1RawDer` behind Application/Context tags issue [#14](https://github.com/Devolutions/picky-rs/issues/14).

## [0.2.1] 2020-01-10

### Added

- `Asn1RawDer` wrapper for user-provided raw DER.

## [0.2.0] 2019-12-23

### Added

- Add `from_reader_with_max_len` deserialization function to limit how many bytes can be read at most.

### Changed

- `from_reader` function has a default limit of 10240 bytes before returning a truncated data error.
    Uses `from_reader_with_max_len` to change the limit.

### Fixed

- Fix various crash found by fuzzing.
