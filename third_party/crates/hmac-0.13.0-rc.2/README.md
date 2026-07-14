# RustCrypto: HMAC

[![crate][crate-image]][crate-link]
[![Docs][docs-image]][docs-link]
[![Build Status][build-image]][build-link]
![Apache2/MIT licensed][license-image]
![Rust Version][rustc-image]
[![Project Chat][chat-image]][chat-link]

Generic implementation of [Hash-based Message Authentication Code (HMAC)][1].

To use it you will need a cryptographic hash function implementation which
implements the [`digest`] crate traits. You can find compatible crates
(e.g. [`sha2`]) in the [`RustCrypto/hashes`] repository.

This crate provides four HMAC implementations: [`Hmac`], [`HmacReset`],
[`SimpleHmac`], and [`SimpleHmacReset`].

The first two types are buffered wrappers around block-level
[`block_api::HmacCore`] and [`block_api::HmacResetCore`] types respectively.
Internally they uses efficient state representation, but work only with
hash functions which expose block-level API and consume blocks eagerly
(e.g. they will not work with the BLAKE2 family of hash functions).

On the other hand, [`SimpleHmac`] and [`SimpleHmacReset`] are a bit less
efficient, but work with all hash functions which implement
the [`Digest`] trait.

[`Hmac`] and [`SimpleHmac`] do not support resetting MAC state (i.e. they
do not implement the [`Reset`] and [`FixedOutputReset`] traits). Use
[`HmacReset`] or [`SimpleHmacReset`] if you want to reuse MAC state.

## Examples

Let us demonstrate how to use HMAC using the SHA-256 hash function
implemented in the [`sha2`] crate.

In the following examples [`Hmac`] is interchangeable with [`SimpleHmac`].

To get authentication code:

```rust
use sha2::Sha256;
use hmac::{Hmac, KeyInit, Mac};
use hex_literal::hex;

// Create alias for HMAC-SHA256
type HmacSha256 = Hmac<Sha256>;

let mut mac = HmacSha256::new_from_slice(b"my secret and secure key")
    .expect("HMAC can take key of any size");
mac.update(b"input message");

// `result` has type `CtOutput` which is a thin wrapper around array of
// bytes for providing constant time equality check
let result = mac.finalize();
// To get underlying array use `into_bytes`, but be careful, since
// incorrect use of the code value may permit timing attacks which defeats
// the security provided by the `CtOutput`
let code_bytes = result.into_bytes();
let expected = hex!("
    97d2a569059bbcd8ead4444ff99071f4
    c01d005bcefe0d3567e1be628e5fdcd9
");
assert_eq!(code_bytes[..], expected[..]);
```

To verify the message:

```rust
use sha2::Sha256;
use hmac::{Hmac, KeyInit, Mac};
use hex_literal::hex;

type HmacSha256 = Hmac<Sha256>;

let mut mac = HmacSha256::new_from_slice(b"my secret and secure key")
    .expect("HMAC can take key of any size");

mac.update(b"input message");

let code_bytes = hex!("
    97d2a569059bbcd8ead4444ff99071f4
    c01d005bcefe0d3567e1be628e5fdcd9
");
// `verify_slice` will return `Ok(())` if code is correct, `Err(MacError)` otherwise
mac.verify_slice(&code_bytes[..]).unwrap();
```

## Block and input sizes

Usually it is assumed that block size is larger than output size. Due to the
generic nature of the implementation, we must handle cases when this assumption
does not hold. This is done by truncating hash output to the hash
block size if needed.

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

[crate-image]: https://img.shields.io/crates/v/hmac.svg?logo=rust
[crate-link]: https://crates.io/crates/hmac
[docs-image]: https://docs.rs/hmac/badge.svg
[docs-link]: https://docs.rs/hmac/
[build-image]: https://github.com/RustCrypto/MACs/actions/workflows/hmac.yml/badge.svg
[build-link]: https://github.com/RustCrypto/MACs/actions/workflows/hmac.yml
[license-image]: https://img.shields.io/badge/license-Apache2.0/MIT-blue.svg
[rustc-image]: https://img.shields.io/badge/rustc-1.85+-blue.svg
[chat-image]: https://img.shields.io/badge/zulip-join_chat-blue.svg
[chat-link]: https://rustcrypto.zulipchat.com/#narrow/stream/260044-MACs

[//]: # (general links)

[1]: https://en.wikipedia.org/wiki/HMAC
[`digest`]: https://docs.rs/digest
[`sha2`]: https://docs.rs/sha2
[`RustCrypto/hashes`]: https://github.com/RustCrypto/hashes

[//]: # (intra-crate links)
[`Reset`]: https://docs.rs/digest/latest/digest/trait.Reset.html
[`Digest`]: https://docs.rs/digest/latest/digest/trait.Digest.html
[`FixedOutputReset`]: https://docs.rs/digest/latest/digest/trait.FixedOutputReset.html
[`Hmac`]: https://docs.rs/hmac/latest/hmac/struct.Hmac.html
[`HmacReset`]: https://docs.rs/hmac/latest/hmac/struct.HmacReset.html
[`SimpleHmac`]: https://docs.rs/hmac/latest/hmac/struct.SimpleHmac.html
[`SimpleHmacReset`]: https://docs.rs/hmac/latest/hmac/struct.SimpleHmacReset.html
[`block_api::HmacCore`]: https://docs.rs/hmac/latest/hmac/block_api/struct.HmacCore.html
[`block_api::HmacResetCore`]: https://docs.rs/hmac/latest/hmac/block_api/struct.HmacResetCore.html
