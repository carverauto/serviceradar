# RustCrypto: AES Key Wrap Algorithm

[![crate][crate-image]][crate-link]
[![Docs][docs-image]][docs-link]
![Apache2/MIT licensed][license-image]
![Rust Version][rustc-image]
[![Build Status][build-image]][build-link]

Pure Rust implementation of the [NIST AES-KW Key Wrap] and
[NIST AES-KWP Key Wrap with Padding] modes also described in [RFC 3394]
and [RFC 5649].

## About

RFC 3394 § 2 describes AES-KW as follows:

> The AES key wrap algorithm is designed to wrap or encrypt key data.
> The key wrap operates on blocks of 64 bits.  Before being wrapped,
> the key data is parsed into n blocks of 64 bits.
> 
> The only restriction the key wrap algorithm places on n is that n be
> at least two.  (For key data with length less than or equal to 64
> bits, the constant field used in this specification and the key data
> form a single 128-bit codebook input making this key wrap
> unnecessary.)  The key wrap algorithm accommodates all supported AES
> key sizes.  However, other cryptographic values often need to be
> wrapped.  One such value is the seed of the random number generator
> for DSS.  This seed value requires n to be greater than four.
> Undoubtedly other values require this type of protection. Therefore,
> no upper bound is imposed on n.
> 
> The AES key wrap can be configured to use any of the three key sizes
> supported by the AES codebook.  The choice of a key size affects the
> overall security provided by the key wrap, but it does not alter the
> description of the key wrap algorithm.  Therefore, in the description
> that follows, the key wrap is described generically; no key size is
> specified for the KEK.

RFC5649 § 1 describes AES-KWP as follows:

> This document specifies an extension of the Advanced Encryption
> Standard (AES) Key Wrap algorithm \[AES-KW1, AES-KW2\].  Without this
> extension, the input to the AES Key Wrap algorithm, called the key
> data, must be a sequence of two or more 64-bit blocks.
>
> The AES Key Wrap with Padding algorithm can be used to wrap a key of
> any practical size with an AES key.  The AES key-encryption key (KEK)
> must be 128, 192, or 256 bits.  The input key data may be as short as
> one octet, which will result in an output of two 64-bit blocks (or 16
> octets).  Although the AES Key Wrap algorithm does not place a
> maximum bound on the size of the key data that can be wrapped, this
> extension does so.  The use of a 32-bit fixed field to carry the
> octet length of the key data bounds the size of the input at 2^32
> octets.  Most systems will have other factors that limit the
> practical size of key data to much less than 2^32 octets.

## Examples

```rust
use hex_literal::hex;
use aes_kw::{KwAes128, KeyInit};

// Key which is used to perform wrapping
let kw_key: [u8; 16] = hex!("000102030405060708090A0B0C0D0E0F");
// Key which will be wrapped
let key: [u8; 16] = hex!("00112233445566778899AABBCCDDEEFF");
// Wrapped key
let wkey: [u8; 24] = hex!("1FA68B0A8112B447AEF34BD8FB5A7B829D3E862371D2CFE5");


let kw = KwAes128::new(&kw_key.into());

let mut buf = [0u8; 24];
kw.wrap_key(&key, &mut buf).unwrap();
assert_eq!(buf, wkey);

let mut buf = [0u8; 16];
kw.unwrap_key(&wkey, &mut buf).unwrap();
assert_eq!(buf, key);

// If key size is known at compile time, you can use the fixed methods:
use aes_kw::cipher::consts::U16;

let wrapped_key = kw.wrap_fixed_key::<U16>(&key.into());
assert_eq!(wrapped_key, wkey);
let unwrapped_key = kw.unwrap_fixed_key::<U16>(&wrapped_key).unwrap();
assert_eq!(unwrapped_key, key);
```

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

[crate-image]: https://img.shields.io/crates/v/aes-kw.svg
[crate-link]: https://crates.io/crates/aes-kw
[docs-image]: https://docs.rs/aes-kw/badge.svg
[docs-link]: https://docs.rs/aes-kw/
[license-image]: https://img.shields.io/badge/license-Apache2.0/MIT-blue.svg
[rustc-image]: https://img.shields.io/badge/rustc-1.85+-blue.svg
[build-image]: https://github.com/RustCrypto/key-wraps/actions/workflows/aes-kw.yml/badge.svg
[build-link]: https://github.com/RustCrypto/key-wraps/actions/workflows/aes-kw.yml

[//]: # (links)

[NIST AES-KW Key Wrap]: https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-38F.pdf
[NIST AES-KWP Key Wrap with Padding]: https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-38F.pdf
[RFC 3394]: https://www.rfc-editor.org/rfc/rfc3394.txt
[RFC 5649]: https://www.rfc-editor.org/rfc/rfc5649.txt
