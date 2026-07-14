# RustCrypto: Cipher Traits

[![crate][crate-image]][crate-link]
[![Docs][docs-image]][docs-link]
![Apache2/MIT licensed][license-image]
![Rust Version][rustc-image]
[![Project Chat][chat-image]][chat-link]
[![Build Status][build-image]][build-link]

Traits which define the functionality of [block ciphers] and [stream ciphers].

See [RustCrypto/block-ciphers] and [RustCrypto/stream-ciphers] for algorithm
implementations which use these traits.

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

[crate-image]: https://img.shields.io/crates/v/cipher.svg
[crate-link]: https://crates.io/crates/cipher
[docs-image]: https://docs.rs/cipher/badge.svg
[docs-link]: https://docs.rs/cipher/
[license-image]: https://img.shields.io/badge/license-Apache2.0/MIT-blue.svg
[rustc-image]: https://img.shields.io/badge/rustc-1.85+-blue.svg
[chat-image]: https://img.shields.io/badge/zulip-join_chat-blue.svg
[chat-link]: https://rustcrypto.zulipchat.com/#narrow/stream/260050-traits
[build-image]: https://github.com/RustCrypto/traits/actions/workflows/cipher.yml/badge.svg?branch=master
[build-link]: https://github.com/RustCrypto/traits/actions/workflows/cipher.yml?query=branch:master

[//]: # (general links)

[block ciphers]: https://en.wikipedia.org/wiki/Block_cipher
[stream ciphers]: https://en.wikipedia.org/wiki/Stream_cipher
[RustCrypto/block-ciphers]: https://github.com/RustCrypto/block-ciphers
[RustCrypto/stream-ciphers]: https://github.com/RustCrypto/stream-ciphers
