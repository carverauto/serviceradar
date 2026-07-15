# [RustCrypto]: Digital Signature Algorithms

[![crate][crate-image]][crate-link]
[![Docs][docs-image]][docs-link]
[![Build Status][build-image]][build-link]
![Apache2/MIT licensed][license-image]
![Rust Version][rustc-image]
[![Project Chat][chat-image]][chat-link]

This crate contains traits which provide generic type-safe APIs for
generating and verifying [digital signatures].

## Supported crates

The following crates are implemented using traits from the `signature` crate:

### RustCrypto crates

- [`dsa`]
- [`ecdsa`]
- [`ed25519`]
- [`ed448`]
- [`ed448-goldilocks`]
- [`lms`]
- [`ml-dsa`]
- [`slh-dsa`]
- [`sm2`]
- [`rsa`]

### Third-party crates

- [`ed25519-dalek`]
- [`yubihsm`]

## SemVer Policy Exemptions

- The off-by-default features `digest` and `rand_core` are unstable features 
  which are also considered exempt from SemVer as they correspond to pre-1.0
  crates which are still subject to changes. Breaking changes to these features
  will, like MSRV, be done with a minor version bump.

## License

Licensed under either of

 * [Apache License, Version 2.0](http://www.apache.org/licenses/LICENSE-2.0)
 * [MIT license](http://opensource.org/licenses/MIT)

at your option.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in the work by you, as defined in the Apache-2.0 license, shall be
dual licensed as above, without any additional terms or conditions.

[//]: # (badges)

[crate-image]:  https://img.shields.io/crates/v/signature
[crate-link]: https://crates.io/crates/signature
[docs-image]: https://docs.rs/signature/badge.svg
[docs-link]: https://docs.rs/signature/
[build-image]: https://github.com/RustCrypto/traits/actions/workflows/signature.yml/badge.svg?branch=master
[build-link]: https://github.com/RustCrypto/traits/actions/workflows/signature.yml?query=branch:master
[license-image]: https://img.shields.io/badge/license-Apache2.0/MIT-blue.svg
[rustc-image]: https://img.shields.io/badge/rustc-1.85+-blue.svg
[chat-image]: https://img.shields.io/badge/zulip-join_chat-blue.svg
[chat-link]: https://rustcrypto.zulipchat.com/#narrow/stream/260048-signatures

[//]: # (links)

[RustCrypto]: https://github.com/RustCrypto/
[digital signatures]: https://en.wikipedia.org/wiki/Digital_signature
[`dsa`]: https://github.com/RustCrypto/signatures/tree/master/dsa
[`ecdsa`]: https://github.com/RustCrypto/signatures/tree/master/ecdsa
[`ed25519`]: https://github.com/RustCrypto/signatures/tree/master/ed25519
[`ed25519-dalek`]: https://github.com/dalek-cryptography/curve25519-dalek/tree/main/ed25519-dalek
[`ed448`]: https://github.com/RustCrypto/elliptic-curves/tree/master/ed448
[`ed448-goldilocks`]: https://github.com/RustCrypto/elliptic-curves/tree/master/ed448-goldilocks
[`lms`]: https://github.com/RustCrypto/signatures/tree/master/lms
[`ml-dsa`]: https://github.com/RustCrypto/signatures/tree/master/ml-dsa
[`rsa`]: https://github.com/RustCrypto/RSA
[`slh-dsa`]: https://github.com/RustCrypto/signatures/tree/master/slh-dsa
[`sm2`]: https://github.com/RustCrypto/elliptic-curves/tree/master/sm2
[`yubihsm`]: https://github.com/iqlusioninc/yubihsm.rs
