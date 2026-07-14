# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.14.0 (UNRELEASED)
### Added
- `elliptic_curve::ops::Invert` implementation ([#971])
- make `LooseFieldElement` pub ([#978])

### Changed
- merge `u576_to_le_bytes` into `FieldBytes::from_uint_unchecked` ([#969])
- switch to upstream RFC6979-based ECDSA ([#1016])
- Update to `elliptic-curve` v0.14 ([#1011])
- Update to `ecdsa` v0.17 ([#1011])
- Update to `sec1` v0.8 ([#1011])
- Update to `secdect` v0.3 ([#1084])
- Update to `rand_core` v0.9 ([#1125])
- Update to `hybrid-array` v0.3 ([#1125])
- Edition changed to 2024 and MSRV bumped to 1.85 ([#1125])
- Relax MSRV policy and allow MSRV bumps in patch releases

[#969]: https://github.com/RustCrypto/elliptic-curves/pull/969
[#971]: https://github.com/RustCrypto/elliptic-curves/pull/971
[#978]: https://github.com/RustCrypto/elliptic-curves/pull/978
[#1011]: https://github.com/RustCrypto/elliptic-curves/pull/1011
[#1016]: https://github.com/RustCrypto/elliptic-curves/pull/1016
[#1084]: https://github.com/RustCrypto/elliptic-curves/pull/1084
[#1125]: https://github.com/RustCrypto/elliptic-curves/pull/1125

## 0.13.3 (2023-11-11)
### Added
- Implement hash2curve ([#964])

### Fixed
- Panics when decoding `FieldElement`s ([#967])

[#964]: https://github.com/RustCrypto/elliptic-curves/pull/964
[#967]: https://github.com/RustCrypto/elliptic-curves/pull/967

## 0.13.2 (2023-11-09)
### Added
- `serde` feature ([#962])

### Changed
- Remove `pub` from `arithmetic` module ([#961])

[#961]: https://github.com/RustCrypto/elliptic-curves/pull/961
[#962]: https://github.com/RustCrypto/elliptic-curves/pull/962

## 0.13.1 (2023-11-09) [YANKED]
### Added
- Bernstein-Yang scalar inversions ([#786])
- VOPRF support ([#924])
- `arithmetic` feature ([#953])
- `ecdh` feature ([#954])
- `ecdsa` feature ([#956])

[#786]: https://github.com/RustCrypto/elliptic-curves/pull/786
[#924]: https://github.com/RustCrypto/elliptic-curves/pull/924
[#953]: https://github.com/RustCrypto/elliptic-curves/pull/953
[#954]: https://github.com/RustCrypto/elliptic-curves/pull/954
[#956]: https://github.com/RustCrypto/elliptic-curves/pull/956

## 0.13.0 (2023-03-03) [YANKED]
- Initial release
