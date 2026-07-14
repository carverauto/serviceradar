# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).


## [[0.15.2](https://github.com/Devolutions/picky-rs/compare/picky-asn1-x509-v0.15.1...picky-asn1-x509-v0.15.2)] - 2025-10-21

### <!-- 7 -->Build

- Remove num-bigint-dig ([#425](https://github.com/Devolutions/picky-rs/issues/425)) ([9081890c3c](https://github.com/Devolutions/picky-rs/commit/9081890c3c4a4b26bb1827b983f40d1c2991550e)) 

## [[0.15.1](https://github.com/Devolutions/picky-rs/compare/picky-asn1-x509-v0.15.0...picky-asn1-x509-v0.15.1)] - 2025-10-10

### <!-- 1 -->Features

- Support parsing certs with MLDSA public keys ([#411](https://github.com/Devolutions/picky-rs/issues/411)) ([abc63dde88](https://github.com/Devolutions/picky-rs/commit/abc63dde88360e35ef225cfd1c279958f47c3abc)) 

## [[0.15.0](https://github.com/Devolutions/picky-rs/compare/picky-asn1-x509-v0.14.6...picky-asn1-x509-v0.15.0)] - 2025-09-26

### <!-- 1 -->Features

- Improve support for SHA3 digests within EC and RSA certificates (#397) ([c898c1a65a](https://github.com/Devolutions/picky-rs/commit/c898c1a65a3a368047354d92cbfd3a6b3aa4f694))

### Changed

- Bump minimal rustc version to 1.85.

## [[0.14.6](https://github.com/Devolutions/picky-rs/compare/picky-asn1-x509-v0.14.5...picky-asn1-x509-v0.14.6)] - 2025-08-18

### <!-- 1 -->Features

- Add smart card logon oid (#394) ([df9a35283f](https://github.com/Devolutions/picky-rs/commit/df9a35283f757bb46d2671e79caeb7b3023ee5e4)) 

## [[0.14.5](https://github.com/Devolutions/picky-rs/compare/picky-asn1-x509-v0.14.4...picky-asn1-x509-v0.14.5)] - 2025-07-15

### <!-- 0 -->Security

- Properly zeroize RsaPrivateKey (#386) ([ace208d604](https://github.com/Devolutions/picky-rs/commit/ace208d604a30f0eb244da1a6408caf145be9d18)) 

  The Drop implementation of the RsaPrivateKey struct was only partially
  zeroizing the secrets.

## [[0.14.4](https://github.com/Devolutions/picky-rs/compare/picky-asn1-x509-v0.14.3...picky-asn1-x509-v0.14.4)] - 2025-06-24

### <!-- 4 -->Bug Fixes

- Invalid parameters for ecdsa with sha512 serialization (#377) ([ee3ed749e6](https://github.com/Devolutions/picky-rs/commit/ee3ed749e6b3d37337be688f8e71e3c799102073)) 

## [[0.14.3](https://github.com/Devolutions/picky-rs/compare/picky-asn1-x509-v0.14.2...picky-asn1-x509-v0.14.3)] - 2025-01-16

### <!-- 4 -->Bug Fixes

- Symlinks to license files in packages (#339) ([1834c04f39](https://github.com/Devolutions/picky-rs/commit/1834c04f3930fb1bbf040deb6525b166e378b8aa)) 

  Use symlinks instead of copying files to avoid a “dirty” state during
  cargo publish and preserve VCS info. With #337 merged, CI handles
  publishing consistently, so developer environments no longer matter.



## [[0.14.2](https://github.com/Devolutions/picky-rs/compare/picky-asn1-x509-v0.14.1...picky-asn1-x509-v0.14.2)] - 2025-01-13

### <!-- 1 -->Features

- `AesAuthEncParams::new` method (#336) ([c33cf22bac](https://github.com/Devolutions/picky-rs/commit/c33cf22bac97a3147d5f99fb74028105b18f0f77)) 

- Add enveloped-data oid (#335) ([c077c72ee9](https://github.com/Devolutions/picky-rs/commit/c077c72ee99caa2c8cf04162c1cccbaced0dc0f5)) 

- Add `ContentInfo` in `pkcs7` module (#334) ([eaa43c36f6](https://github.com/Devolutions/picky-rs/commit/eaa43c36f6976aa8f54e51ee4a64fbe626d6938f)) 


## [0.14.1] 2024-11-26

### Changed

- `picky-test-data` is a new dev-dependency.
- Update dependencies.

## [0.14.0] 2024-11-19

### Added

- `EnvelopedData` and related structures
- API to query and set MAC algorithm for PFX
- Protection descriptors OIDs

### Fixed

- Better algorithm identifier parsing

## [0.13.0] 2024-07-12

### Changed

- Bump minimal rustc version to 1.61
- Update dependencies

## [0.12.0] 2023-08-24

### Added

- PKCS12 ASN.1 structures
- USER_PRINCIPAL_NAME oid

### Fixed

- License files are now correctly included in the published package

### Changed

- Update dependencies

## [0.11.0] 2023-08-03

### Added

- PKCS12 module

### Changed

- Renamed `oids::pkcs7` to correct `oids::content_info_type_data`

## [0.10.0] 2023-06-15

### Fixed

- Fixed `AlgorithmIdentifier` parsing: made `ECParameters` non-optional for EC keys
- Fixed `ECParameters` - `public_key` now allowed to be optional
- Fixed broken wasm compilation

### Added

- `oid` is now added as re-export
- New API methods:
    - `EcParameters::curve_oid`
    - `PrivateKeyInfo::new_ec_encryption`
    - `signature::EcdsaSignatureValue`
    - `AlgorithmIdentifier::is_one_of`
    - `AlgorithmIdentifier::new_x25519`
    - `AlgorithmIdentifier::new_ed448`
    - `AlgorithmIdentifier::new_x448`
    - `PrivateKeyInfo::new_ed_encryption`
    - `SubjectPublicKeyInfo::new_ed_key`
- New constants:
    - `private_key_info::PRIVATE_KEY_INFO_VERSION_1`
    - `private_key_info::PRIVATE_KEY_INFO_VERSION_2`
- Support of Ed25519/X25519/Ed448/X448 key structures

### Changed

- (Breaking) `AlgorithmIdentifier::new_elliptic_curve` now accepts `EcParameters` instead of `impl Into<Option<EcParameters>>`
- (Breaking) `AlgorithmIdentifierParameters::Ec` now have `EcParameters` instead of `Option<EcParameters>`
- (Breaking) `SubjectPublicKeyInfo::new_ec_key` now accepts curve's `ObjectIdentifier` and point as `BitString`
- `PrivateKeyInfo` structure now also could represent newer `OneAsymmetricKey` structure
  (structures are backward-compatible). This allows to represent Ed keys with public key field set

## [0.9.0] 2022-11-07

### Added

- More OIDs such as PKINIT_AUTH_DATA and PKINIT_DH_KEY_DATA
- Support for BMPString

## [0.8.0] 2022-08-01

### Added

- Implement `Zeroize` on `ECPrivateKey` and `RsaPrivateKey` (behind feature `zeroize`)

### Changed

- Bump minimal rustc version to 1.60

## [0.7.1] 2022-05-20

### Added

- OIDs used by NLA protocols

## [0.7.0] 2022-03-04

### Added

- Support for Authenticode timestamp deserialization/serialization
- CTL implementation behind `ctl` feature
- New `SpcSipInfo` struct
- Add serialization/deserialization of Authenticode `TimestampRequest`
- Add timestamp request OID
- Add a few methods for creating an Attribute without usage low-level API:
  - `Attribute::new_content_type_pkcs7`
  - `Attribute::new_signing_time`
  - `Attribute::new_message_digest`
- Add `EncapsulatedContentInfo::new_pkcs7_data` method

### Changed

- (Breaking) `ShaVariant` enum is extended for MD5 and SH1 algorithms
- (Breaking) Add `SpcStatementType` variant in `AttributeValues` enum
- (Breaking) Add `SigningTime` variant in `AttributeValues` enum
- `SpcAttributeAndOptionalValue` now supports both `SpcPeImageData` and `SpcSipInfo` values
- Bump minimal rustc version to 1.56

### Fixed

- SignedData:
  - (Breaking) `RevocationInfoChoice` field is now optional as specified by the RFC
  - (Breaking) `CertificateSet` is now a `Vec<CertificateChoices>` which can accept both a normal `Certificate` and an `other` kind of certificate as specified by the RFC

## [0.6.1] 2021-06-02

### Added

- More ECC OIDs ([#87](https://github.com/Devolutions/picky-rs/pull/87))

## [0.6.0] 2021-05-27

### Added

- Support for V1 and V2 X509 certificates ([#83](https://github.com/Devolutions/picky-rs/pull/83))
- Support for `CrlNumber` extension ([#83](https://github.com/Devolutions/picky-rs/pull/83))
- PKCS7 implementation behind `pkcs7` feature ([#83](https://github.com/Devolutions/picky-rs/pull/83))

### Changed

- More supported attribute values: `ContentType`, `MessageDigest` and `SpcSpOpusInfo` ([#83](https://github.com/Devolutions/picky-rs/pull/83))
- Fix clippy upper case acronyms warning in a few places ([#85](https://github.com/Devolutions/picky-rs/pull/85))

### Removed

- Remove `ImplicitCurve` from `EcParameters` enum ([#85](https://github.com/Devolutions/picky-rs/pull/85))

## [0.5.0] 2021-03-04

### Added

- Support for attributes in `CertificationRequestInfo` ([#78](https://github.com/Devolutions/picky-rs/pull/78))

## [0.4.0] 2020-11-20

### Added

- OIDs from RFC8410 ([#72](https://github.com/Devolutions/picky-rs/pull/72))
- Support for Ed25519 `AlgorithmIdentifier` and `PublicKey` ([#72](https://github.com/Devolutions/picky-rs/pull/72))

## [0.3.4] 2020-10-21

### Changed

- `AlgorithmIdentifier` parser has been made more lenient.
  For instance, `rsa-export-0.1.1` crate does not serialize the "NULL" parameter with rsa encryption OID.
  Such input is not rejected anymore.

## [0.3.3] 2020-10-13

### Added

- Documentation on `oids` module.

## [0.3.2] 2020-09-04

### Added

- `legacy` feature to support previously valid `RSAPrivateKey` with 6 components instead of 9 as specified by the RFC.
  Missing components are instead computed on the fly as required.

## [0.3.1] 2020-08-31

### Changed

- Update dependencies

## [0.3.0] 2020-08-21

### Added

- `DigestInfo` from RFC8017

### Changed

- `RSAPrivateKey` fields are now `pub`
- `PrivateKeyInfo::new_rsa_encryption` takes 6 arguments instead of 8

### Deprecated

- `RSAPrivateKey` getters are deprecated in favor of direct access of public fields

## [0.2.0] 2020-08-20

### Added

- NIST signature related OIDs
- `AlgorithmIdentifier::new_sha3_384_with_rsa_encryption` constructor
- `AlgorithmIdentifier::new_sha3_512_with_rsa_encryption` constructor
- Support for email attribute in certificate subject

### Changed

- Rename "organisation" to "organization"
- Change attribute structure in directory names to follow common practices

### Fixed

- `RSAPrivateKey` is now RFC8017 compliant
