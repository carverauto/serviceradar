# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
