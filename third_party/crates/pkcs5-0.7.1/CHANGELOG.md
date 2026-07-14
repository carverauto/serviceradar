# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.7.1 (2023-03-05)
### Changed
- Bump `pbkdf2` to v0.12 ([#913])
- Bump `scrypt` to v0.11 ([#913])

[#913]: https://github.com/RustCrypto/formats/pull/913

## 0.7.0 (2023-02-26) [YANKED]
### Changed
- Bump `der` dependency to v0.7 ([#899])
- Bump `spki` dependency to v0.7 ([#900])

[#899]: https://github.com/RustCrypto/formats/pull/899
[#900]: https://github.com/RustCrypto/formats/pull/900

## 0.6.0 (Skipped)
- Skipped to synchronize version number with `der` and `spki`

## 0.5.0 (2022-05-08)
### Changed
- Update `hmac`, `pbkdf2`, and `sha2`
- Update cipher v0.4 crates ([#411])
- Switch from `sha-1` to `sha1`; `sha1` feature is renamed to `sha1-insecure` ([#426])
- Bump `scrypt` dependency to v0.9 ([#441])
- Bump `der` to v0.6 ([#653])
- Bump `spki` to v0.6 ([#654])

[#411]: https://github.com/RustCrypto/formats/pull/411
[#426]: https://github.com/RustCrypto/formats/pull/426
[#441]: https://github.com/RustCrypto/formats/pull/441
[#653]: https://github.com/RustCrypto/formats/pull/653
[#654]: https://github.com/RustCrypto/formats/pull/654

## 0.4.0 (2021-11-15)
### Changed
- Introduce `Error` enum with new error cases ([#26])
- Introduce specialized `Result` type for crate ([#26])
- Rust 2021 edition upgrade; MSRV 1.56 ([#136])
- Bump `der` dependency to v0.5 ([#222])
- Bump `spki` dependency to v0.5 ([#223])

### Removed
- Legacy DES encryption support ([#25])

[#25]: https://github.com/RustCrypto/formats/pull/25
[#26]: https://github.com/RustCrypto/formats/pull/26
[#136]: https://github.com/RustCrypto/formats/pull/136
[#222]: https://github.com/RustCrypto/formats/pull/222
[#223]: https://github.com/RustCrypto/formats/pull/223

## 0.3.2 (2021-09-14)
### Added
- `3des` and `des-insecure` features
- `sha1` feature
- Support for AES-192-CBC

### Changed
- Moved to `formats` repo ([#2])

[#2]: https://github.com/RustCrypto/formats/pull/2

## 0.3.1 (2021-08-30)
### Changed
- Bump `scrypt` dependency to 0.8
- Bump `pbkdf2` dependency to v0.9

## 0.3.0 (2021-06-07)
### Changed
- Bump `der` crate dependency to v0.4
- Bump `spki` crate dependency to v0.4

## 0.2.2 (2021-05-26)
### Added
- `scrypt` support as specified in RFC 7914

## 0.2.1 (2021-04-29)
### Changed
- Bump `aes` to v0.7
- Bump `block-modes` to v0.8
- Bump `hmac` to v0.11
- Bump `pbkdf2` to v0.8

## 0.2.0 (2021-03-22)
### Changed
- Bump `der` to v0.3
- Bump `spki` to v0.3

## 0.1.1 (2021-02-23)
### Added
- Encryption support

## 0.1.0 (2021-02-20)
- Initial release
