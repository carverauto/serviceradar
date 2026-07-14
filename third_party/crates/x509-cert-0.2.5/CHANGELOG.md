# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.2.5 (2023-12-23)

### Added
- Signed Certificate Timestamp (SCT) extension support ([#1134])

### Changed
- Relax dependencies ([#1179])
- Use `SubjectPublicKeyInfoOwned::from_key` ([#1271])

[#1134]: https://github.com/RustCrypto/formats/pull/1134
[#1179]: https://github.com/RustCrypto/formats/pull/1179
[#1271]: https://github.com/RustCrypto/formats/pull/1271

## 0.2.4 (2023-07-25)

### Added
- `add_attribute` to `RequestBuilder` ([#1137])

### Changed
- bump `serde_json` from 1.0.97 to 1.0.99 ([#1122])
- use the shortest name when looking attr OID ([#1130])
- bump `serde_json` from 1.0.100 to 1.0.103 ([#1158])

### Fixed
- RDN string representation ([#1126])
- `Arbitrary` for certificates ([#1150])

[#1122]: https://github.com/RustCrypto/formats/pull/1122
[#1126]: https://github.com/RustCrypto/formats/pull/1126
[#1130]: https://github.com/RustCrypto/formats/pull/1130
[#1137]: https://github.com/RustCrypto/formats/pull/1137
[#1150]: https://github.com/RustCrypto/formats/pull/1150
[#1158]: https://github.com/RustCrypto/formats/pull/1158

## 0.2.3 (2023-05-30)

### Added
- Added `TryFrom` for `RelativeDistinguishedName` ([#1092])
- Load a chain of certificates from a slice ([#1081])

[#1092]: https://github.com/RustCrypto/formats/pull/1092
[#1081]: https://github.com/RustCrypto/formats/pull/1081

## 0.2.2 (2023-05-19)

### Added
- Certificate builder ([#764])
- Support for `RandomizedSigner` in builder ([#1007])
- Provide parsing profiles ([#987])
- Support for `Time::INFINITY` ([#1024])
- Conversion from `std::net::IpAddr` ([#1035])
- `CertReq` builder ([#1034])
- missing extension implementations ([#1050])
- notes about `UTCTime` range being 1970-2049 ([#1052])
- consume the `SignatureBitStringEncoding` trait ([#1048])

### Changed
- use `ErrorKind::Value` for overlength serial ([#988])
- Bump `hex-literal` to v0.4.1 ([#999])
- Builder updates ([#1001])
- better debug info when `zlint` isn't installed ([#1018])
- make SKI optional in leaf certificate ([#1028])
- bump rsa from 0.9.0-pre.2 to 0.9.0 ([#1033])
- bump rsa from 0.9.1 to 0.9.2 ([#1056])

### Fixed
- fix `KeyUsage` bit tests ([#993])
- extraneous PhantomData in `TbsCertificate` ([#1017])
- CI flakiness ([#1042])
- usage of ecdsa signer ([#1043])

[#764]: https://github.com/RustCrypto/formats/pull/764
[#987]: https://github.com/RustCrypto/formats/pull/987
[#988]: https://github.com/RustCrypto/formats/pull/988
[#993]: https://github.com/RustCrypto/formats/pull/993
[#999]: https://github.com/RustCrypto/formats/pull/999
[#1001]: https://github.com/RustCrypto/formats/pull/1001
[#1007]: https://github.com/RustCrypto/formats/pull/1007
[#1017]: https://github.com/RustCrypto/formats/pull/1017
[#1018]: https://github.com/RustCrypto/formats/pull/1018
[#1024]: https://github.com/RustCrypto/formats/pull/1024
[#1028]: https://github.com/RustCrypto/formats/pull/1028
[#1033]: https://github.com/RustCrypto/formats/pull/1033
[#1034]: https://github.com/RustCrypto/formats/pull/1034
[#1035]: https://github.com/RustCrypto/formats/pull/1035
[#1042]: https://github.com/RustCrypto/formats/pull/1042
[#1043]: https://github.com/RustCrypto/formats/pull/1043
[#1048]: https://github.com/RustCrypto/formats/pull/1048
[#1050]: https://github.com/RustCrypto/formats/pull/1050
[#1052]: https://github.com/RustCrypto/formats/pull/1052
[#1056]: https://github.com/RustCrypto/formats/pull/1056

## 0.2.1 (2023-03-26)
### Added
- `FromStr` impls for `RdnSequence` (`Name`), `RelativeDistinguishedName`, and
  `AttributeTypeAndValue` ([#949])

### Changed
- Deprecate `encode_from_string` functions ([#951])

[#949]: https://github.com/RustCrypto/formats/pull/949
[#951]: https://github.com/RustCrypto/formats/pull/951

## 0.2.0 (2023-03-18)
### Added
- Feature-gated `Arbitrary` impl for `Certificate` ([#761])
- Allow request to be serialized to PEM ([#819])
- `Display` impl for `SerialNumber` ([#820])
- `std` feature implies `const-oid/std` ([#874])

### Changed
- Serial numbers are formatted as `PrintableString` ([#794])
- `SerialNumber` is now a specialized object ([#795])
- MSRV 1.65 ([#805])
- Make types owned instead of reference-based ([#806], [#841])
- Bump `der` to v0.7 ([#899])
- Bump `spki` to v0.7 ([#900])

### Fixed
- Handling of negative serial numbers ([#823], [#831])

### Removed
- `alloc` feature: now unconditionally required ([#841])

[#761]: https://github.com/RustCrypto/formats/pull/761
[#794]: https://github.com/RustCrypto/formats/pull/794
[#795]: https://github.com/RustCrypto/formats/pull/795
[#805]: https://github.com/RustCrypto/formats/pull/805
[#806]: https://github.com/RustCrypto/formats/pull/806
[#819]: https://github.com/RustCrypto/formats/pull/819
[#820]: https://github.com/RustCrypto/formats/pull/820
[#823]: https://github.com/RustCrypto/formats/pull/823
[#831]: https://github.com/RustCrypto/formats/pull/831
[#841]: https://github.com/RustCrypto/formats/pull/841
[#874]: https://github.com/RustCrypto/formats/pull/874
[#899]: https://github.com/RustCrypto/formats/pull/899
[#900]: https://github.com/RustCrypto/formats/pull/900

## 0.1.1 (2022-12-10)
### Added
- Support `TeletexString` in `DirectoryString` ([#692])
- Re-export `spki` ([#701])
- `PemLabel` impl for `Certificate` ([#763])
- `ValueOrd` impl for `Version` and other derived types ([#723])

### Fixed
-  `countryName` should always be `PrintableString` ([#760])

[#692]: https://github.com/RustCrypto/formats/pull/692
[#701]: https://github.com/RustCrypto/formats/pull/701
[#723]: https://github.com/RustCrypto/formats/pull/723
[#760]: https://github.com/RustCrypto/formats/pull/760
[#763]: https://github.com/RustCrypto/formats/pull/763

## 0.1.0 (2022-07-23)
- Initial release
