# RustCrypto: GHASH

[![crate][crate-image]][crate-link]
[![Docs][docs-image]][docs-link]
[![Build Status][build-image]][build-link]
![Apache2/MIT licensed][license-image]
![Rust Version][rustc-image]
[![Project Chat][chat-image]][chat-link]
[![HAZMAT][hazmat-image]][hazmat-link]

[GHASH][1] is a [universal hash function][2] which operates over GF(2^128) and
can be used for constructing a [Message Authentication Code (MAC)][3].

Its primary intended use is for implementing [AES-GCM][4].

## Security

### ⚠️ Warning: [Hazmat!][hazmat-link]

Universal hash functions have subtle security properties and are primarily intended as a 
building block for constructions like AEAD algorithms.

USE AT YOUR OWN RISK!

### Security Notes

This crate has received one [security audit by NCC Group][5], with no significant
findings. We would like to thank [MobileCoin][6] for funding the audit.

All implementations contained in the crate are designed to execute in constant
time, either by relying on hardware intrinsics (i.e. AVX2 on x86/x86_64), or
using a portable implementation which is only constant time on processors which
implement constant-time multiplication.

It is not suitable for use on processors with a variable-time multiplication
operation (e.g. short circuit on multiply-by-zero / multiply-by-one, such as
certain 32-bit PowerPC CPUs and some non-ARM microcontrollers).

## Implementation Notes

The implementation of GHASH found in this crate internally uses the
[`polyval`][7] crate, which provides a similar universal hash function used by
AES-GCM-SIV (RFC 8452).

By implementing GHASH in terms of POLYVAL, the two universal hash functions
can share a common core, meaning any optimization work (e.g. CPU-specific
SIMD implementations) which happens upstream in the `polyval` crate
benefits GHASH as well.

From [RFC 8452 Appendix A][8]:

> GHASH and POLYVAL both operate in GF(2^128), although with different
> irreducible polynomials: POLYVAL works modulo x^128 + x^127 + x^126 +
> x^121 + 1 and GHASH works modulo x^128 + x^7 + x^2 + x + 1.  Note
> that these irreducible polynomials are the "reverse" of each other.

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

[crate-image]: https://img.shields.io/crates/v/ghash.svg?logo=rust
[crate-link]: https://crates.io/crates/ghash
[docs-image]: https://docs.rs/ghash/badge.svg
[docs-link]: https://docs.rs/ghash/
[chat-image]: https://img.shields.io/badge/zulip-join_chat-blue.svg
[chat-link]: https://rustcrypto.zulipchat.com/#narrow/channel/260051-universal-hashes
[license-image]: https://img.shields.io/badge/license-Apache2.0/MIT-blue.svg
[rustc-image]: https://img.shields.io/badge/rustc-1.85+-blue.svg
[build-image]: https://github.com/RustCrypto/universal-hashes/actions/workflows/ghash.yml/badge.svg?branch=master
[build-link]: https://github.com/RustCrypto/universal-hashes/actions/workflows/ghash.yml?query=branch:master
[hazmat-image]: https://img.shields.io/badge/crypto-hazmat%E2%9A%A0-red.svg
[hazmat-link]: https://github.com/RustCrypto/meta/blob/master/HAZMAT.md

[//]: # (footnotes)

[1]: https://en.wikipedia.org/wiki/Galois/Counter_Mode#Mathematical_basis
[2]: https://en.wikipedia.org/wiki/Universal_hashing
[3]: https://en.wikipedia.org/wiki/Message_authentication_code
[4]: https://en.wikipedia.org/wiki/Galois/Counter_Mode
[5]: https://research.nccgroup.com/2020/02/26/public-report-rustcrypto-aes-gcm-and-chacha20poly1305-implementation-review/
[6]: https://www.mobilecoin.com/
[7]: https://docs.rs/polyval/
[8]: https://tools.ietf.org/html/rfc8452#appendix-A
