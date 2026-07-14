# RustCrypto: HKDF

[![crate][crate-image]][crate-link]
[![Docs][docs-image]][docs-link]
![Apache2/MIT licensed][license-image]
![Rust Version][rustc-image]
[![Project Chat][chat-image]][chat-link]
[![Build Status][build-image]][build-link]

Pure Rust implementation of the [HMAC-based Extract-and-Expand Key Derivation Function (HKDF)](https://tools.ietf.org/html/rfc5869) generic over hash function.

# Usage

The most common way to use HKDF is as follows: you provide the Initial Key Material (IKM) and an optional salt, then you expand it (perhaps multiple times) into some Output Key Material (OKM) bound to an "info" context string.

```rust
use sha2::Sha256;
use hkdf::Hkdf;
use hex_literal::hex;

let ikm = hex!("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b");
let salt = hex!("000102030405060708090a0b0c");
let info = hex!("f0f1f2f3f4f5f6f7f8f9");

let hk = Hkdf::<Sha256>::new(Some(&salt[..]), &ikm);
let mut okm = [0u8; 42];
hk.expand(&info, &mut okm)
    .expect("42 is a valid length for Sha256 to output");

let expected = hex!("
    3cb25f25faacd57a90434f64d0362f2a
    2d2d0a90cf1a5a4c5db02d56ecc4c5bf
    34007208d5b887185865
");
assert_eq!(okm, expected);
```

Normally the PRK (Pseudo-Random Key) remains hidden within the HKDF object, but if you need to access it, use `Hkdf::extract` instead of `Hkdf::new`.

```rust
use sha2::Sha256;
use hkdf::Hkdf;
use hex_literal::hex;

let ikm = hex!("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b");
let salt = hex!("000102030405060708090a0b0c");

let (prk, hk) = Hkdf::<Sha256>::extract(Some(&salt[..]), &ikm);
let expected = hex!("
    077709362c2e32df0ddc3f0dc47bba63
    90b6c73bb50f9c3122ec844ad7c2b3e5
");
assert_eq!(prk[..], expected[..]);
```

If you already have a strong key to work from (uniformly-distributed and
long enough), you can save a tiny amount of time by skipping the extract
step. In this case, you pass a Pseudo-Random Key (PRK) into the
`Hkdf::from_prk` constructor, then use the resulting `Hkdf` object
as usual.

```rust
use sha2::Sha256;
use hkdf::Hkdf;
use hex_literal::hex;

let salt = hex!("000102030405060708090a0b0c");
let info = hex!("f0f1f2f3f4f5f6f7f8f9");
 
let prk = hex!("
    077709362c2e32df0ddc3f0dc47bba63
    90b6c73bb50f9c3122ec844ad7c2b3e5
");

let hk = Hkdf::<Sha256>::from_prk(&prk).expect("PRK should be large enough");
let mut okm = [0u8; 42];
hk.expand(&info, &mut okm)
    .expect("42 is a valid length for Sha256 to output");

let expected = hex!("
    3cb25f25faacd57a90434f64d0362f2a
    2d2d0a90cf1a5a4c5db02d56ecc4c5bf
    34007208d5b887185865
");
assert_eq!(okm, expected);
```

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

[crate-image]: https://img.shields.io/crates/v/hkdf.svg
[crate-link]: https://crates.io/crates/hkdf
[docs-image]: https://docs.rs/hkdf/badge.svg
[docs-link]: https://docs.rs/hkdf/
[license-image]: https://img.shields.io/badge/license-Apache2.0/MIT-blue.svg
[rustc-image]: https://img.shields.io/badge/rustc-1.85+-blue.svg
[chat-image]: https://img.shields.io/badge/zulip-join_chat-blue.svg
[chat-link]: https://rustcrypto.zulipchat.com/#narrow/stream/260043-KDFs
[build-image]: https://github.com/RustCrypto/KDFs/workflows/hkdf/badge.svg?branch=master&event=push
[build-link]: https://github.com/RustCrypto/KDFs/actions?query=workflow:hkdf
