# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## UNRELEASED
### Added
- `AssociatedOid` implementations ([#35])

### Changed
- Bump `aes` dependency to v0.9 ([#34])
- `Kek` type is split into separate `AesKw` and `AesKwp` types ([#40])
- `wrap` and `unwrap` methods now return resulting slice ([#40])
- Edition changed to 2024 and MSRV bumped to 1.85 ([#47])
- Relax MSRV policy and allow MSRV bumps in patch releases

### Removed
- `Kek::new` inherent method in favor of implementing `InnerInit` ([#40])
- `From`/`Into` impls from key into key-wrapper types ([#40])
- `IV`, `KWP_IV_PREFIX`, and `KWP_MAX_LEN` constants ([#40])

[#34]: https://github.com/RustCrypto/key-wraps/pull/34
[#35]: https://github.com/RustCrypto/key-wraps/pull/35
[#40]: https://github.com/RustCrypto/key-wraps/pull/40
[#47]: https://github.com/RustCrypto/key-wraps/pull/47

## 0.2.1 (2022-04-20)
### Changed
- Use `encrypt_with_backend`/`decrypt_with_backend` methods ([#19])

[#19]: https://github.com/RustCrypto/key-wraps/pull/19

## 0.2.0 (2022-02-10)
### Changed
- Bump `aes` dependency to v0.8 ([#14])

[#14]: https://github.com/RustCrypto/key-wraps/pull/14

## 0.1.0 (2022-01-06)
- Initial release
