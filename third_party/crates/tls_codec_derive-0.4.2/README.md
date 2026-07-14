# [RustCrypto]: TLS Codec

![MIT licensed][license-image]
[![Project Chat][chat-image]][chat-link]
[![][tls_codec-ci]][tls_codec-ci-link]
![Rust Version][rustc-image]

|                    | crates.io                                      | docs.rs                                                      |
| ------------------ | ---------------------------------------------- | ------------------------------------------------------------ |
| `tls_codec`        | [![][tls_codec]][tls_codec-link]               | [![Docs][tls_codec_docs]][tls_codec_docs-link]               |
| `tls_codec_derive` | [![][tls_codec_derive]][tls_codec_derive-link] | [![Docs][tls_codec_derive_docs]][tls_codec_derive_docs-link] |

This crate implements the TLS codec as defined in [RFC 8446]
as well as some extensions required by [MLS].

With the `derive` feature `TlsSerialize` and `TlsDeserialize` can be
derived.

The crate also provides the following data structures that implement TLS
serialization/deserialization

- `u8`, `u16`, `u32`, `u64`
- `TlsVecU8`, `TlsVecU16`, `TlsVecU32`
- `SecretTlsVecU8`, `SecretTlsVecU16`, `SecretTlsVecU32`
  The same as the `TlsVec*` versions but it implements zeroize, requiring
  the elements to implement zeroize as well.
- `TlsSliceU8`, `TlsSliceU16`, `TlsSliceU32` are lightweight wrapper for slices
  that allow to serialize them without having to create a `TlsVec*`.
- `TlsByteSliceU8`, `TlsByteSliceU16`, `TlsByteSliceU32`, and
  `TlsByteVecU8`, `TlsByteVecU16`, `TlsByteVecU32`
  are provided with optimized implementations for byte vectors.
- `[u8; l]`, for `l ∈ [1..128]`
- Serialize for `Option<T>` where `T: Serialize`
- Deserialize for `Option<T>` where `T: Deserialize`
- Serialize for `(T, U)` and `(T, U, V)` where `T, U, V` implement Serialize`
- Deserialize for `(T, U)` and `(T, U, V)` where `T, U, V` implement Deserialize`

## Minimum Supported Rust Version

This crate requires **Rust 1.74.0** at a minimum.

We may change the MSRV in the future, but it will be accompanied by a minor
version bump.

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

[chat-image]: https://img.shields.io/badge/zulip-join_chat-blue.svg?style=for-the-badge
[chat-link]: https://rustcrypto.zulipchat.com/#narrow/stream/300570-formats
[license-image]: https://img.shields.io/badge/license-Apache2.0-blue.svg?style=for-the-badge
[rustc-image]: https://img.shields.io/badge/rustc-1.70+-blue.svg?style=for-the-badge

[//]: # (links)

[RustCrypto]: https://github.com/rustcrypto
[rfc 8446]: https://tools.ietf.org/html/rfc8446
[mls]: https://www.rfc-editor.org/rfc/rfc9420.html
[tls_codec-ci]: https://img.shields.io/github/actions/workflow/status/RustCrypto/formats/tls_codec.yml?branch=master&style=for-the-badge
[tls_codec-ci-link]: https://github.com/RustCrypto/formats/actions/workflows/tls_codec.yml
[tls_codec]: https://img.shields.io/crates/v/tls_codec?style=for-the-badge
[tls_codec-link]: https://crates.io/crates/tls_codec
[tls_codec_docs]: https://img.shields.io/docsrs/tls_codec/latest?style=for-the-badge
[tls_codec_docs-link]: https://docs.rs/tls_codec/
[tls_codec_derive]: https://img.shields.io/crates/v/tls_codec_derive?style=for-the-badge
[tls_codec_derive-link]: https://crates.io/crates/tls_codec_derive
[tls_codec_derive_docs]: https://img.shields.io/docsrs/tls_codec_derive/latest?style=for-the-badge
[tls_codec_derive_docs-link]: https://docs.rs/tls_codec_derive/
