# [RustCrypto]: Constant-Time Serde Helpers

[![Crate][crate-image]][crate-link]
[![Docs][docs-image]][docs-link]
[![Build Status][build-image]][build-link]
![Apache 2.0/MIT Licensed][license-image]
![Rust Version][rustc-image]
[![Project Chat][chat-image]][chat-link]

Constant-time serde serializer/deserializer helpers for data that potentially
contains secrets (e.g. cryptographic keys)

[Documentation][docs-link]

## About

[Serialization is a potential sidechannel for leaking sensitive secrets][Util::Lookup]
such as cryptographic keys.

This crate provides "best effort" constant-time helper methods for reducing
the amount of timing variability involved in serializing/deserializing data
when using `serde`, Rust's standard serialization framework.

These helper methods conditionally serialize data as hexadecimal using the
constant-time [`base16ct`] crate when using human-readable formats such as
JSON or TOML. When using a binary format, the data is serialized as-is into
binary.

While this crate can't ensure that format implementations don't perform
other kinds of data-dependent branching on the contents of the serialized data,
using a constant-time hex serialization with human-readable formats should
help reduce the overall timing variability.

`serdect` is tested against the following crates:
- [`bincode`](https://crates.io/crates/bincode) v2
- [`ciborium`](https://crates.io/crates/ciborium) v0.2
- [`rmp-serde`](https://crates.io/crates/rmp-serde) v1
- [`serde-json-core`](https://crates.io/crates/serde-json-core) v0.5
- [`serde-json`](https://crates.io/crates/serde-json) v1
- [`toml`](https://crates.io/crates/toml) v0.8

## Minimum Supported Rust Version (MSRV) Policy

MSRV increases are not considered breaking changes and can happen in patch releases.

The crate MSRV accounts for all supported targets and crate feature combinations, excluding
explicitly unstable features.

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

[crate-image]: https://img.shields.io/crates/v/serdect
[crate-link]: https://crates.io/crates/serdect
[docs-image]: https://docs.rs/serdect/badge.svg
[docs-link]: https://docs.rs/serdect/
[build-image]: https://github.com/RustCrypto/formats/actions/workflows/serdect.yml/badge.svg
[build-link]: https://github.com/RustCrypto/formats/actions/workflows/serdect.yml
[license-image]: https://img.shields.io/badge/license-Apache2.0/MIT-blue.svg
[rustc-image]: https://img.shields.io/badge/rustc-1.85+-blue.svg
[chat-image]: https://img.shields.io/badge/zulip-join_chat-blue.svg
[chat-link]: https://rustcrypto.zulipchat.com/#narrow/stream/300570-formats

[//]: # (general links)

[RustCrypto]: https://github.com/RustCrypto
[Util::Lookup]: https://arxiv.org/pdf/2108.04600.pdf
[`base16ct`]: https://github.com/RustCrypto/formats/tree/master/base16ct
