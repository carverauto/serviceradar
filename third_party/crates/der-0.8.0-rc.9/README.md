# [RustCrypto]: ASN.1 DER

[![Crate][crate-image]][crate-link]
[![Docs][docs-image]][docs-link]
[![Build Status][build-image]][build-link]
![Apache2/MIT licensed][license-image]
![Rust Version][rustc-image]
[![Project Chat][chat-image]][chat-link]

Pure Rust embedded-friendly implementation of the Distinguished Encoding Rules (DER)
for Abstract Syntax Notation One (ASN.1) as described in [ITU X.690].

[Documentation][docs-link]

## About

This crate provides a `no_std`-friendly implementation of a subset of ASN.1 DER
necessary for decoding/encoding the following cryptography-related formats
implemented as crates maintained by the [RustCrypto] project:

- [`cms`]: Cryptographic Message Syntax
- [`pkcs1`]: RSA Cryptography Specifications
- [`pkcs5`]: Password-Based Cryptography Specification
- [`pkcs8`]: Private-Key Information Syntax Specification
- [`pkcs12`]: Personal Information Exchange Syntax
- [`sec1`]: Elliptic Curve Cryptography
- [`spki`]: X.509 Subject Public Key Info
- [`x509-cert`]: Public Key Infrastructure Certificate
- [`x509-ocsp`]: Online Certificate Status Protocol

The core implementation avoids any heap usage (with convenience methods
that allocate gated under the off-by-default `alloc` feature).

The DER decoder in this crate performs checks to ensure that the input document
is in canonical form, and will return errors if non-canonical productions are
encountered. There is currently no way to disable these checks.

### Features

- Rich support for ASN.1 types used by PKCS/PKIX documents
- Performs DER canonicalization checks at decoding time
- `no_std` friendly: supports "heapless" usage
- Optionally supports `alloc` and `std` if desired
- No hard dependencies! Self-contained implementation with optional
  integrations with the following crates, all of which are `no_std` friendly:
  - `const-oid`: const-friendly OID implementation
  - `pem-rfc7468`: PKCS/PKIX-flavored PEM library with constant-time decoder/encoders
  - `time` crate: date/time library

## License

Licensed under either of:

 * [Apache License, Version 2.0](http://www.apache.org/licenses/LICENSE-2.0)
 * [MIT license](http://opensource.org/licenses/MIT)

at your option.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in the work by you, as defined in the Apache-2.0 license, shall be
dual licensed as above, without any additional terms or conditions.

[//]: # (badges)

[crate-image]: https://img.shields.io/crates/v/der?logo=rust
[crate-link]: https://crates.io/crates/der
[docs-image]: https://docs.rs/der/badge.svg
[docs-link]: https://docs.rs/der/
[build-image]: https://github.com/RustCrypto/formats/actions/workflows/der.yml/badge.svg
[build-link]: https://github.com/RustCrypto/formats/actions/workflows/der.yml
[license-image]: https://img.shields.io/badge/license-Apache2.0/MIT-blue.svg
[rustc-image]: https://img.shields.io/badge/rustc-1.85+-blue.svg
[chat-image]: https://img.shields.io/badge/zulip-join_chat-blue.svg
[chat-link]: https://rustcrypto.zulipchat.com/#narrow/stream/300570-formats

[//]: # (links)

[RustCrypto]: https://github.com/rustcrypto
[ITU X.690]: https://www.itu.int/rec/T-REC-X.690/en
[`cms`]: https://github.com/RustCrypto/formats/tree/master/cms
[`pkcs1`]: https://github.com/RustCrypto/formats/tree/master/pkcs1
[`pkcs5`]: https://github.com/RustCrypto/formats/tree/master/pkcs5
[`pkcs8`]: https://github.com/RustCrypto/formats/tree/master/pkcs8
[`pkcs12`]: https://github.com/RustCrypto/formats/tree/master/pkcs12
[`sec1`]: https://github.com/RustCrypto/formats/tree/master/sec1
[`spki`]: https://github.com/RustCrypto/formats/tree/master/spki
[`x509-cert`]: https://github.com/RustCrypto/formats/tree/master/x509-cert
[`x509-ocsp`]: https://github.com/RustCrypto/formats/tree/master/x509-ocsp
