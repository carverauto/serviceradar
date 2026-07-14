# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).


## [[0.10.1](https://github.com/Devolutions/picky-rs/compare/picky-asn1-v0.10.0...picky-asn1-v0.10.1)] - 2025-01-16

### <!-- 4 -->Bug Fixes

- Symlinks to license files in packages (#339) ([1834c04f39](https://github.com/Devolutions/picky-rs/commit/1834c04f3930fb1bbf040deb6525b166e378b8aa)) 

  Use symlinks instead of copying files to avoid a “dirty” state during
  cargo publish and preserve VCS info. With #337 merged, CI handles
  publishing consistently, so developer environments no longer matter.


## [0.10.0] 2024-11-26

### Fixed

- `picky-asn1-der` is now a dev-dependency of the released crate, to fix test build.

### Changed

- Bump minimal rustc version to 1.70

## [0.9.0] 2024-07-12

### Changed

- Bump minimal rustc version to 1.61
- Update dependencies

## [0.8.0] 2023-08-23

### Fixed

- License files are now correctly included in the published package
- BMP string charset was incorrectly validated

### Changed

- Rename `UTCTime`, `IA5CharSet`, `IA5String`, `BMPCharSet` and `BMPString` into
  `UtcTime`, `Ia5CharSet`, `Ia5String`, `BmpCharSet` and `BmpString` to follow the Rust convention
  that is to count acronyms and contractions of compound words as one word.

  Newer types are re-exported with the old naming in order to mitigate breaking downstream breakage,
  but just in case this is not a "patch" bump.

- Update dependencies

## [0.7.2] 2023-03-27

### Fixed

- ASN.1 Integer minimal encoding ([#209](https://github.com/Devolutions/picky-rs/pull/209))

## [0.7.1] 2022-11-07

### Changed

- Debug representation of `BitString`, `RestrictedString`, `OctetStringAsn1` and `IntegerAsn1` in hexadecimal

## [0.7.0] 2022-11-07

### Added

- `BitString::as_inner` method

## [0.6.0] 2022-08-01

### Added

- Implement `Zeroize` for `IntegerAsn1` (behind the `zeroize` feature)

### Changed

- Bump minimal rustc version to 1.60

## [0.5.0] 2022-02-02

### Added

- `Optional::is_default`
- Support for `time 0.3` types conversions behind `time_conversion` feature gate
- Implement `Default` for `Optional<T>` when `T: Default`
- Added `GeneralString`

### Changed

- Bump minimal rustc version to 1.56

## [0.4.0] 2021-08-09

### Changed

- Rename `Tag::number` into `Tag::inner`
- Rename `ApplicationTag{0-15}` into `ExplicitContextTag{0-15}`
- Rename `ContextTag{0-15}` into `ImplicitContextTag{0-15}`
- Rename `Implicit` into `Optional`

### Added

- `Tag::is_primitive`
- `Tag::application_primitive`
- `Tag::application_constructed`
- `Tag::context_specific_primitive`
- `Tag::context_specific_constructed`
- `Tag::number`
- `Tag::class`
- `Tag::class_and_number`
- `Tag::components`
- `Tag::is_application`
- `Tag::is_context_specific`
- `Tag::is_universal`
- `Tag::is_private`
- `Tag::is_constructed`
- `Tag::is_primitive`
- `Tag::encoding`
- `TagClass`
- `Encoding`

### Removed

- `Tag::APP_{0-15}`
- `Tag::CTX_{0-15}`
- `Tag::application`
- `Tag::context_specific`

## [0.3.3] 2021-07-02

### Fixed

- Support for rustc 1.43 (accidently bumped in 0.3.2). See [#89](https://github.com/Devolutions/picky-rs/issues/89).

## [0.3.2] 2021-05-27

### Added

- Support for `BMPString`
- Implement `Default` for `IA5StringAsn1`, `Asn1SetOf`, `Utf8String`, `IA5String`

## [0.3.1] 2021-01-11

### Fixed

- Fix bad `use`s statements to `serde::export`

## [0.3.0] 2020-08-31

### Changed

- Rename `IntegerAsn1`'s `from_unsigned_bytes_be` to `from_bytes_be_unsigned`
- Rename `IntegerAsn1`'s `from_signed_bytes_be` to `from_bytes_be_signed`

## [0.2.2] 2020-07-07

### Changed

- Dependencies clean up

## [0.2.1] 2020-01-13

### Fixed

- Check for index out of bound in `IntegerAsn1::from_unsigned_bytes_be`

## [0.2.0] 2020-01-10

### Added

- Add `IntegerAsn1::from_unsigned_bytes_be`

### Changed

- Rename `IntegerAsn1::as_bytes_be` to `IntegerAsn1::as_unsigned_bytes_be`.
