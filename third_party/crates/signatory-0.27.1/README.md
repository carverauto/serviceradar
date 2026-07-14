# ![Signatory][logo]

[![crate][crate-image]][crate-link]
[![Docs][docs-image]][docs-link]
![Apache2/MIT licensed][license-image]
![MSRV][rustc-image]
[![Build Status][build-image]][build-link]

Pure Rust digital signature library with support for elliptic curve digital
signature algorithms, namely ECDSA ([FIPS 186‑4]) and Ed25519 ([RFC 8032]).

[Documentation][docs-link]

## About

This crate provides a thread-and-object-safe API for both creating and
verifying elliptic curve digital signatures, using either software-based
or hardware-based providers.

The following algorithms are supported:

- [ECDSA]: Elliptic Curve Digital Signature Algorithm ([FIPS 186‑4])
- [Ed25519]: Edwards Digital Signature Algorithm (EdDSA) instantiated using
  the twisted Edwards form of Curve25519 ([RFC 8032]).

## Minimum Supported Rust Version

Rust **1.65** or newer.

In the future, we reserve the right to change MSRV (i.e. MSRV is out-of-scope
for this crate's SemVer guarantees), however when we do it will be accompanied by
a minor version bump.

## License

**Signatory** is distributed under your choice of the terms of the MIT license
and/or the Apache License (Version 2.0).

See [LICENSE-APACHE](LICENSE-APACHE) and [LICENSE-MIT](LICENSE-MIT) for details.

## Contribution

Unless you explicitly state otherwise, any contribution intentionally
submitted for inclusion in the work by you shall be dual licensed as above,
without any additional terms or conditions.

[//]: # (badges)

[logo]: https://storage.googleapis.com/iqlusion-production-web/github/signatory/signatory.svg
[crate-image]: https://img.shields.io/crates/v/signatory.svg
[crate-link]: https://crates.io/crates/signatory
[docs-image]: https://docs.rs/signatory/badge.svg
[docs-link]: https://docs.rs/signatory/
[license-image]: https://img.shields.io/badge/license-Apache2.0/MIT-blue.svg
[rustc-image]: https://img.shields.io/badge/rustc-1.65+-blue.svg
[build-image]: https://github.com/iqlusioninc/crates/workflows/signatory/badge.svg?branch=main&event=push
[build-link]: https://github.com/iqlusioninc/crates/actions

[//]: # (general links)

[ECDSA]: https://en.wikipedia.org/wiki/Elliptic_Curve_Digital_Signature_Algorithm
[Ed25519]: https://en.wikipedia.org/wiki/EdDSA#Ed25519
[FIPS 186‑4]: https://csrc.nist.gov/publications/detail/fips/186/4/final
[RFC 8032]: https://tools.ietf.org/html/rfc8032
