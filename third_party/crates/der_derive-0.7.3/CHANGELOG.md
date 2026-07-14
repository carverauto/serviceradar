# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.7.3 (2024-07-09)
### Changed
- avoid type inference when using default ([#1443])

[#1443]: https://github.com/RustCrypto/formats/pull/1443

## 0.7.2 (2023-08-07)
### Changed
- fix doc typo and use a valid tag number ([#1184])
- remove proc-macro-error dependency ([#1180])

[#1180]: https://github.com/RustCrypto/formats/pull/1180
[#1184]: https://github.com/RustCrypto/formats/pull/1184

## 0.7.1 (2023-04-19)
### Added
 - Support for type generics in `Sequence` macro ([#1014])

[#1014]: https://github.com/RustCrypto/formats/pull/1014

## 0.7.0 (2023-02-26)
### Changed
- Eliminate dynamism from encoding ([#828])

[#828]: https://github.com/RustCrypto/formats/pull/828

## 0.6.1 (2022-12-05)
### Added
- Support for deriving `ValueOrd` on `Choice` enums ([#723])

[#723]: https://github.com/RustCrypto/formats/pull/723

## 0.6.0 (2022-05-08)
### Added
- Support for Context-Specific fields with default values ([#246])
- Context-Specific tags on `#[derive(Sequence)]` ([#349])
- `#[asn1(constructed = "true")]` ([#398])

### Changed
- Have `Sequence` macro derive `DecodeValue` ([#375])
- Pass `Header` to `DecodeValue` ([#392])
- Have `Choice` macro derive `EncodeValue` ([#395])
- Only emit `.try_into()?` when a type is specified ([#397])
- Use type's tag by default on `derive(Choice)` ([#416])

### Fixed
- Length calculation for explicit tags ([#400])

### Removed
- Static lifetime from ENUMERATED's derived `DecodeValue` ([#367])

[#246]: https://github.com/RustCrypto/formats/pull/246
[#349]: https://github.com/RustCrypto/formats/pull/349
[#367]: https://github.com/RustCrypto/formats/pull/367
[#375]: https://github.com/RustCrypto/formats/pull/375
[#392]: https://github.com/RustCrypto/formats/pull/392
[#395]: https://github.com/RustCrypto/formats/pull/395
[#397]: https://github.com/RustCrypto/formats/pull/397
[#398]: https://github.com/RustCrypto/formats/pull/398
[#400]: https://github.com/RustCrypto/formats/pull/400
[#416]: https://github.com/RustCrypto/formats/pull/416

## 0.5.0 (2021-11-15)
### Added
- `asn1(tag_mode = "...")` derive attribute ([#150])
- `asn1(context_specific = "...")` derive attribute ([#150])
- `Enumerated` custom derive macro ([#171])
- `asn1(tag_mode = "...")` attribute ([#197])
- Support for handling `DEFAULT` values of `SEQUENCE`s ([#202])
- `ValueOrd` custom derive macro ([#206])
- `CONTEXT-SPECIFIC` support for `Sequence` custom derive ([#220])

### Changed
- Rename `Message` trait to `Sequence` ([#99])
- Rust 2021 edition upgrade; MSRV 1.56 ([#136])

### Removed
- Don't automatically derive `From` impls for `Choice` ([#168])

[#99]: https://github.com/RustCrypto/formats/pull/99
[#136]: https://github.com/RustCrypto/formats/pull/136
[#150]: https://github.com/RustCrypto/formats/pull/150
[#168]: https://github.com/RustCrypto/formats/pull/150
[#171]: https://github.com/RustCrypto/formats/pull/171
[#197]: https://github.com/RustCrypto/formats/pull/197
[#202]: https://github.com/RustCrypto/formats/pull/202
[#206]: https://github.com/RustCrypto/formats/pull/206
[#220]: https://github.com/RustCrypto/formats/pull/220

## 0.4.1 (2021-09-14)
### Changed
- Moved to `formats` repo ([#2])

[#2]: https://github.com/RustCrypto/formats/pull/2

## 0.4.0 (2021-06-07)
### Changed
- Update generated code to support the corresponding `der` crate changes

## 0.3.0 (2021-03-21)
### Added
- `choice::Alternative` and duplicate tracking
- Auto-derive `From` impls for variants when deriving `Choice`

## 0.2.2 (2021-02-22)
### Added
- Custom derive support for the `Choice` trait

## 0.2.1 (2021-02-15)
### Added
- Custom derive support for enums

## 0.2.0 (2021-02-02)
### Added
- Support for `PrintableString` and `Utf8String`

## 0.1.0 (2020-12-21)
- Initial release
