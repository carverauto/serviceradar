# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.10.2 (2026-01-07)
### Added
- `ObjectIdentifier::from_bytes_sized` which ensures OIDs use all available space in the backing
  array ([#1852])
- Microsoft and Kerberos OIDs ([#2035])

### Fixed
- Switch from `doc_auto_cfg` to `doc_cfg` ([#2072])

[#1852]: https://github.com/RustCrypto/formats/pull/1852
[#2035]: https://github.com/RustCrypto/formats/pull/2035
[#2072]: https://github.com/RustCrypto/formats/pull/2072

## 0.10.1 (2025-04-08)
### Added
- RFC9688 OIDs ([#1692])

### Fixed
- Encoder `base128_len` calculation ([#1753])

[#1692]: https://github.com/RustCrypto/formats/pull/1692
[#1753]: https://github.com/RustCrypto/formats/pull/1753

## 0.10.0 (2025-02-24)
### Added
- `ObjectIdentifier::starts_with` ([#964])
- SHA-3 OIDs ([#1000])
- RFC6962 OIDs ([#1094])
- RFC2985 OIDS for PKCS#9 ([#1248])
- `ObjectIdentifierRef` type ([#1305], [#1308])
- RFC7693 OIDs for BLAKE2 ([#1261])
- TPM-related OIDs ([#1337])
- STB (Belarus standards) OIDs ([#1394])
- RFC3161 OIDs ([#1407])
- OIDs for ML-DSA and SLH-DSA ([#1541])
- RFC5753 OIDs ([#1547])
- RFC7292 OIDs for PKCS#12 ([#1568])
- Brainpool RFC5639 OIDs ([#1636])
- Support for X.509 `GN` as an alias to `givenName` ([#1648])

### Changed
- Return all matched names when looking up OID ([#1129])
- Make `ObjectIdentifier`'s size const generic ([#1300])
- Upgrade to 2024 edition; MSRV 1.85 ([#1670])

### Fixed
- Off-by-one error in `Encoder` size check ([#1304])
- Large arc handling ([#1522], [#1592])
- Handling of repeated dot characters in input ([#1595])
- Bugs in Base 128 encoder ([#1600])

### Removed
- `std` feature ([#1535])

[#964]: https://github.com/RustCrypto/formats/pull/964
[#1000]: https://github.com/RustCrypto/formats/pull/1000
[#1094]: https://github.com/RustCrypto/formats/pull/1094
[#1248]: https://github.com/RustCrypto/formats/pull/1248
[#1261]: https://github.com/RustCrypto/formats/pull/1261
[#1300]: https://github.com/RustCrypto/formats/pull/1300
[#1304]: https://github.com/RustCrypto/formats/pull/1304
[#1305]: https://github.com/RustCrypto/formats/pull/1305
[#1337]: https://github.com/RustCrypto/formats/pull/1337
[#1394]: https://github.com/RustCrypto/formats/pull/1394
[#1407]: https://github.com/RustCrypto/formats/pull/1407
[#1522]: https://github.com/RustCrypto/formats/pull/1522
[#1535]: https://github.com/RustCrypto/formats/pull/1535
[#1541]: https://github.com/RustCrypto/formats/pull/1541
[#1547]: https://github.com/RustCrypto/formats/pull/1547
[#1568]: https://github.com/RustCrypto/formats/pull/1568
[#1592]: https://github.com/RustCrypto/formats/pull/1529
[#1595]: https://github.com/RustCrypto/formats/pull/1595
[#1600]: https://github.com/RustCrypto/formats/pull/1600
[#1636]: https://github.com/RustCrypto/formats/pull/1636
[#1648]: https://github.com/RustCrypto/formats/pull/1648
[#1670]: https://github.com/RustCrypto/formats/pull/1670

## 0.9.6 (2023-12-15)
### Added
- RFC6962 (Certificate Transparency) OIDs ([#1134])

[#1134]: https://github.com/RustCrypto/formats/pull/1134

## 0.9.5 (2023-08-02)
### Added
- RFC8410 (curve25519) OIDs ([#867])

[#867]: https://github.com/RustCrypto/formats/pull/867

## 0.9.4 (2023-07-10)
### Added
- RFC8894 (SCEP) OIDs ([#1114])

[#1114]: https://github.com/RustCrypto/formats/pull/1114

## 0.9.3 (2023-06-29)
### Added
- `Database::find_names_for_oid` ([#1129])

[#1129]: https://github.com/RustCrypto/formats/pull/1129

## 0.9.2 (2023-02-26)
### Added
- `arbitrary` crate feature ([#895])

[#895]: https://github.com/RustCrypto/formats/pull/895

## 0.9.1 (2022-11-12)
### Added
- clippy lints for checked arithmetic and panics ([#561])
- `DynAssociatedOid` trait ([#758])

[#561]: https://github.com/RustCrypto/formats/pull/561
[#758]: https://github.com/RustCrypto/formats/pull/758

## 0.9.0 (2022-03-11)
### Added
- Fallible `const fn` parser + `::new_unwrap` ([#458], [#459])
- OID database gated under the `db` feature ([#451], [#453], [#456], [#488])
- `AssociatedOid` trait ([#479])
- `ObjectIdentifier::push_arc` ([#504])
- `ObjectIdentifier::parent` ([#505])

### Changed
- `ObjectIdentifier::new` now returns a `Result` ([#458])

[#451]: https://github.com/RustCrypto/formats/pull/451
[#453]: https://github.com/RustCrypto/formats/pull/453
[#456]: https://github.com/RustCrypto/formats/pull/456
[#458]: https://github.com/RustCrypto/formats/pull/458
[#459]: https://github.com/RustCrypto/formats/pull/459
[#479]: https://github.com/RustCrypto/formats/pull/479
[#488]: https://github.com/RustCrypto/formats/pull/488
[#504]: https://github.com/RustCrypto/formats/pull/504
[#505]: https://github.com/RustCrypto/formats/pull/505

## 0.8.0 (2022-01-17)
### Changed
- Leverage `const_panic`; MSRV 1.57 ([#341])

[#341]: https://github.com/RustCrypto/formats/pull/341

## 0.7.1 (2021-11-30)
### Changed
- Increase `MAX_SIZE` to 39 ([#258])

[#258]: https://github.com/RustCrypto/formats/pull/258

## 0.7.0 (2021-11-14) [YANKED]
### Changed
- Rust 2021 edition upgrade; MSRV 1.56 ([#136])
- Rename `MAX_LENGTH` to `MAX_SIZE`; bump to `31` ([#174])
- Make `length` the first field of `ObjectIdentifier` ([#178])

### Fixed
- `debug_assert!` false positive on large arc ([#180])

[#136]: https://github.com/RustCrypto/formats/pull/136
[#174]: https://github.com/RustCrypto/formats/pull/174
[#178]: https://github.com/RustCrypto/formats/pull/178
[#180]: https://github.com/RustCrypto/formats/pull/180

## 0.6.2 (2021-10-14)
### Fixed
- Off-by-one error parsing large BER arcs ([#84])

[#84]: https://github.com/RustCrypto/formats/pull/84

## 0.6.1 (2021-09-14) [YANKED]
### Changed
- Moved to `formats` repo ([#2])

[#2]: https://github.com/RustCrypto/formats/pull/2

## 0.6.0 (2021-06-03) [YANKED]
### Changed
- Modernize and remove deprecations; MSRV 1.51+

## 0.5.2 (2021-04-20)
### Added
- Expand README.md

## 0.5.1 (2021-04-15)
### Added
- `ObjectIdentifier::MAX_LENGTH` constant

### Changed
- Deprecate `ObjectIdentifier::max_len()` function

## 0.5.0 (2021-03-21)
### Added
- `TryFrom<&[u8]>` impl on `ObjectIdentifier`

## Changed
- MSRV 1.47+
- Renamed the following methods:
  - `ObjectIdentifier::new` => `ObjectIdentifier::from_arcs`
  - `ObjectIdentifier::parse` => `ObjectIdentifier::new`
  - `ObjectIdentifier::from_ber` => `ObjectIdentifier::from_bytes`

### Removed
- Deprecated methods
- `alloc` feature - only used by aforementioned deprecated methods
- `TryFrom<&[Arc]>` impl on `ObjectIdentifier` - use `::from_arcs`

## 0.4.5 (2021-03-04)
### Added
- `Hash` and `Ord` impls on `ObjectIdentifier`

## 0.4.4 (2021-02-28)
### Added
- `ObjectIdentifier::as_bytes` method

### Changed
- Internal representation changed to BER/DER
- Deprecated `ObjectIdentifier::ber_len`, `::write_ber`, and `::to_ber`

## 0.4.3 (2021-02-24)
### Added
- Const-friendly OID string parser

## 0.4.2 (2021-02-19)
### Fixed
- Bug in root arc calculation

## 0.4.1 (2020-12-21)
### Fixed
- Bug in const initializer

## 0.4.0 (2020-12-16)
### Added
- `Arcs` iterator

### Changed
- Rename "nodes" to "arcs"
- Layout optimization
- Refactor and improve length limits

## 0.3.5 (2020-12-12)
### Added
- `ObjectIdentifier::{write_ber, to_ber}` methods

## 0.3.4 (2020-12-06)
### Changed
- Documentation improvements

## 0.3.3 (2020-12-05)
### Changed
- Improve description in Cargo.toml/README.md

## 0.3.2 (2020-12-05)
### Changed
- Documentation improvements

## 0.3.1 (2020-12-05)
### Added
- Impl `TryFrom<&[u32]>` for ObjectIdentifier

## 0.3.0 (2020-12-05) [YANKED]
### Added
- Byte and string parsers

## 0.2.0 (2020-09-05)
### Changed
- Validate OIDs are well-formed; MSRV 1.46+

## 0.1.0 (2020-08-04)
- Initial release
