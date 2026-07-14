# [RustCrypto]: Cryptographic Big Integers

[![crate][crate-image]][crate-link]
[![Docs][docs-image]][docs-link]
[![Build Status][build-image]][build-link]
![Apache2/MIT licensed][license-image]
![Rust Version][rustc-image]
[![Project Chat][chat-image]][chat-link]

Pure Rust implementation of a big integer library which has been designed from
the ground-up for use in cryptographic applications.

Provides constant-time, `no_std`-friendly implementations of modern formulas
using const generics.

[Documentation][docs-link]

## Goals

- Supports `no_std`-friendly const generic stack-allocated big integers.
- Constant-time by default. Variable-time functions are explicitly marked as such.
- Leverage what is possible today with const generics on `stable` rust.
- Support `const fn` as much as possible with the goal of being able to compute
  values at compile-time.
- Optional heap-allocated `Boxed*` types gated under an `alloc` feature.

## Security Notes

This crate has been [audited by NCC Group] with no significant
findings. We would like to thank [Entropy] for funding the audit.

All functions contained in the crate are designed to execute in constant
time unless explicitly specified otherwise (via a `*_vartime` name suffix).

This library is not suitable for use on processors with a variable-time
multiplication operation (e.g. short circuit on multiply-by-zero /
multiply-by-one, such as certain 32-bit PowerPC CPUs and some non-ARM
microcontrollers).

## License

Licensed under either of:

- [Apache License, Version 2.0](http://www.apache.org/licenses/LICENSE-2.0)
- [MIT license](http://opensource.org/licenses/MIT)

at your option.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in the work by you, as defined in the Apache-2.0 license, shall be
dual licensed as above, without any additional terms or conditions.

[//]: # (badges)

[crate-image]: https://img.shields.io/crates/v/crypto-bigint?logo=rust
[crate-link]: https://crates.io/crates/crypto-bigint
[docs-image]: https://docs.rs/crypto-bigint/badge.svg
[docs-link]: https://docs.rs/crypto-bigint/
[build-image]: https://github.com/RustCrypto/crypto-bigint/actions/workflows/crypto-bigint.yml/badge.svg?branch=master
[build-link]: https://github.com/RustCrypto/crypto-bigint/actions/workflows/crypto-bigint.yml?query=branch:master
[license-image]: https://img.shields.io/badge/license-Apache2.0/MIT-blue.svg
[rustc-image]: https://img.shields.io/badge/rustc-1.85+-blue.svg
[chat-image]: https://img.shields.io/badge/zulip-join_chat-blue.svg
[chat-link]: https://rustcrypto.zulipchat.com/#narrow/stream/300602-crypto-bigint

[//]: # (links)

[RustCrypto]: https://github.com/rustcrypto
[audited by NCC Group]: https://www.nccgroup.com/us/research-blog/public-report-entropyrust-cryptography-review/
[Entropy]: https://entropy.xyz/
