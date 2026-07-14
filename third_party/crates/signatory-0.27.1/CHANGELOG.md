# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.27.1 (2023-08-14)
### Changed
- Bump `ed25519-dalek` to v2.0 ([#1167])

[#1167]: https://github.com/iqlusioninc/crates/pull/1167

## 0.27.0 (2023-04-05)
### Changed
- Bump `ecdsa`to v0.16 ([#1105])
- Bump `k256` to v0.13 ([#1105])
- Bump `p256` to v0.13 ([#1105])
- Bump `p384` to v0.13 ([#1105])
- Bump `ed25519-dalek` to 2.0.0-rc.2 ([#1113])

[#1105]: https://github.com/iqlusioninc/crates/pull/1105
[#1113]: https://github.com/iqlusioninc/crates/pull/1113

## 0.26.0 (2022-08-19)
### Added
- `Send + Sync` bounds to inner `Box` for signer types ([#1037])
- ECDSA/P-384 support ([#1039])

[#1037]: https://github.com/iqlusioninc/crates/pull/1037
[#1039]: https://github.com/iqlusioninc/crates/pull/1039

## 0.25.0 (2022-05-17)
### Changed
- Bump `ecdsa` to v0.14 ([#994])
- Bump `k256` to v0.11 ([#994])
- Bump `p256` to v0.11 ([#994])
- Bump `pkcs8` to v0.9 ([#994])
- Bump `sha2` to v0.10 ([#994])
- MSRV 1.57 ([#994])

[#994]: https://github.com/iqlusioninc/crates/pull/994

## 0.24.0 (2022-01-05)
### Changed
- Rust 2021 edition upgrade ([#889])
- Bump `k256` dependency to v0.10 ([#938])

[#889]: https://github.com/iqlusioninc/crates/pull/889
[#938]: https://github.com/iqlusioninc/crates/pull/938

## 0.23.2 (2021-08-02)
### Added
- `ed25519::VerifyingKey::to_bytes` ([#834])

[#834]: https://github.com/iqlusioninc/crates/pull/834

## 0.23.1 (2021-07-21)
### Added
- `Algorithm::EcdsaNistP256` and `Algorithm::Ed25519` variants ([#817])

[#817]: https://github.com/iqlusioninc/crates/pull/817

## 0.23.0 (2021-07-20)
### Changed
This release is effectively a complete rewrite of Signatory with a brand-new
API, and as such contains changes too numerous to document. For that reason,
we are pushing the reset button on the changelog.

It still provides the same original set of functionality, including ECDSA and
Ed25519 signatures, but temporarily drops support for P-384 and hardware-backed
digital signature providers.

The plan is to eventually add this functionality back. The new implementation
is fundamentally built on the same original codebase, but refactored and
extracted into other Rust crates. Given that, we hope to achieve feature
parity with the original implementation quickly.
