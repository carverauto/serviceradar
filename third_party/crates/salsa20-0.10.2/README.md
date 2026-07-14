# RustCrypto: Salsa20 Stream Cipher

[![Crate][crate-image]][crate-link]
[![Docs][docs-image]][docs-link]
![Apache2/MIT licensed][license-image]
![Rust Version][rustc-image]
[![Project Chat][chat-image]][chat-link]
[![Build Status][build-image]][build-link]
[![HAZMAT][hazmat-image]][hazmat-link]

Pure Rust implementation of the [Salsa20 Stream Cipher][1].

[Documentation][docs-link]

<img src="https://raw.githubusercontent.com/RustCrypto/meta/master/img/stream-ciphers/salsa20.png" width="300px">

## About

[Salsa20][1] is a [stream cipher][2] which is designed to support
high-performance software implementations.

This crate also contains an implementation of [XSalsa20][3]: a variant
of Salsa20 with an extended 192-bit (24-byte) nonce, gated under the
`xsalsa20` Cargo feature (on-by-default).

## ⚠️ Security Warning: [Hazmat!][hazmat-link]

This crate does not ensure ciphertexts are authentic (i.e. by using a MAC to
verify ciphertext integrity), which can lead to serious vulnerabilities
if used incorrectly!

No security audits of this crate have ever been performed, and it has not been
thoroughly assessed to ensure its operation is constant-time on common CPU
architectures.

USE AT YOUR OWN RISK!

## Minimum Supported Rust Version

Rust **1.56** or higher.

Minimum supported Rust version can be changed in the future, but it will be
done with a minor version bump.

## SemVer Policy

- All on-by-default features of this library are covered by SemVer
- MSRV is considered exempt from SemVer as noted above

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

[crate-image]: https://img.shields.io/crates/v/salsa20.svg
[crate-link]: https://crates.io/crates/salsa20
[docs-image]: https://docs.rs/salsa20/badge.svg
[docs-link]: https://docs.rs/salsa20/
[license-image]: https://img.shields.io/badge/license-Apache2.0/MIT-blue.svg
[rustc-image]: https://img.shields.io/badge/rustc-1.56+-blue.svg
[chat-image]: https://img.shields.io/badge/zulip-join_chat-blue.svg
[chat-link]: https://rustcrypto.zulipchat.com/#narrow/stream/260049-stream-ciphers
[hazmat-image]: https://img.shields.io/badge/crypto-hazmat%E2%9A%A0-red.svg
[hazmat-link]: https://github.com/RustCrypto/meta/blob/master/HAZMAT.md
[build-image]: https://github.com/RustCrypto/stream-ciphers/workflows/salsa20/badge.svg?branch=master&event=push
[build-link]: https://github.com/RustCrypto/stream-ciphers/actions?query=workflow%3Asalsa20

[//]: # (footnotes)

[1]: https://en.wikipedia.org/wiki/Salsa20
[2]: https://en.wikipedia.org/wiki/Stream_cipher
[3]: https://cr.yp.to/snuffle/xsalsa-20081128.pdf
[4]: https://github.com/RustCrypto/AEADs/tree/master/xsalsa20poly1305
