# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.4.3 (2026-05-03)
### Added
- `no_alloc` implementation of `serialize_hex` ([#2327])

[#2327]: https://github.com/RustCrypto/formats/pull/2327

## 0.4.2 (2026-01-03)
### Changed
- Bump `base16ct` to v1 ([#2145])

[#2145]: https://github.com/RustCrypto/formats/pull/2145

## 0.4.1 (2025-09-01)
### Changed
- Bump `base16ct` to v0.3 ([#2017])

[#2017]: https://github.com/RustCrypto/formats/pull/2017

## 0.4.0 (2025-08-20)
### Changed
- Upgrade to the 2024 edition; MSRV 1.85 ([#1670])

[#1670]: https://github.com/RustCrypto/formats/pull/1670

## 0.3.0 (2025-01-06)

NOTE: this release includes major breaking changes to the wire format, namely
all bytestrings now include a length prefix, even when serializing fixed-size
arrays. This is intended to work around deficiencies in the `serde` API
(see serde-rs/serde#2120) as well as serde-based format implementations which
have variable-time behavior when using `serialize_tuple`.

Any binary data serialized with previous versions of `serdect` now needs a
length prefix prepended to the data, which will vary depending on the
particular data format.

### Changed
- Switch to length-prefixed encoding using the `serialize_bytes` method ([#1112], [#1515])
- MSRV 1.70 ([#1244])

[#1112]: https://github.com/RustCrypto/formats/pull/1112
[#1515]: https://github.com/RustCrypto/formats/pull/1515
[#1244]: https://github.com/RustCrypto/formats/pull/1244

## 0.2.0 (2023-02-26)
### Changed
- MSRV 1.60 ([#802])
- Lint improvements ([#824])
- Bump `base16ct` dependency to v0.2 ([#890])

### Fixed
- TOML test ([#864])

[#802]: https://github.com/RustCrypto/formats/pull/802
[#824]: https://github.com/RustCrypto/formats/pull/824
[#864]: https://github.com/RustCrypto/formats/pull/864
[#890]: https://github.com/RustCrypto/formats/pull/890

## 0.1.0 (2022-03-29)
- Initial release
