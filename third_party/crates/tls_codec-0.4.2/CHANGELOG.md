# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## 0.4.2

- [#1628](https://github.com/RustCrypto/formats/pull/1628) Bump MSRV to 1.74

## 0.4.1

- [#1284](https://github.com/RustCrypto/formats/pull/1284): implement `U24`. A `U24` integer type can be used for length encoding in three bytes.
- [#1159](https://github.com/RustCrypto/formats/pull/1159): Read and write all available data in `VLBytes`. Before this change the read or write may have failed when it couldn't be read/written all at once.
- [#1330](https://github.com/RustCrypto/formats/pull/1330): Introduce helper macro for conditional deserialization. This change introduces the `#[tls_codec(cd_field)]` macro. It can be used alongside the `#[conditionally_deserializable]` macro to mark fields that are also conditionally deserializable and that internally need to have the const generic added.

## 0.4.0

### Changed

- [#1251](https://github.com/RustCrypto/formats/pull/1251): Add `_bytes` suffix to function names in the `DeserializeBytes` trait to avoid collisions with function names in the `Deserialize` trait
- [#1135](https://github.com/RustCrypto/formats/pull/1135): `no_std` support for the derive crate. This requires the `std` feature to be enabled when using derive with `Serialize` and `Deserialize`.

### Removed

- [#1251](https://github.com/RustCrypto/formats/pull/1251): Remove the `tls_deserialize_bytes` function from the `Deserialize` trait
