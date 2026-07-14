# [RustCrypto]: Hybrid Const Generic / Typenum Arrays

[![crate][crate-image]][crate-link]
[![Docs][docs-image]][docs-link]
[![Build Status][build-image]][build-link]
[![codecov][coverage-image]][coverage-link]
![Apache2/MIT licensed][license-image]
![Rust Version][rustc-image]
[![Project Chat][chat-image]][chat-link]

Hybrid array type combining const generics with the expressiveness of
[`typenum`]-based constraints, providing an alternative to [`generic-array`]
and a incremental transition path to const generics.

## About

This crate uses `typenum` to enable the following features which aren't yet
possible with the stable implementation of const generics:

- [#60551: Associated constants in traits can not be used in const generics][rust-issue-60551]
- [#76560: Complex generic constants: `feature(generic_const_exprs)`][rust-issue-76560]

Internally the crate is built on const generics and provides traits which make
it possible to convert between const generic types and `typenum` types.

## Minimum Supported Rust Version (MSRV) Policy

MSRV increases are not considered breaking changes and can happen in patch
releases.

The crate MSRV accounts for all supported targets and crate feature
combinations, excluding explicitly unstable features.

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

[crate-image]: https://img.shields.io/crates/v/hybrid-array?logo=rust
[crate-link]: https://crates.io/crates/hybrid-array
[docs-image]: https://docs.rs/hybrid-array/badge.svg
[docs-link]: https://docs.rs/hybrid-array/
[build-image]: https://github.com/RustCrypto/hybrid-array/actions/workflows/hybrid-array.yml/badge.svg?branch=master
[build-link]: https://github.com/RustCrypto/hybrid-array/actions/workflows/hybrid-array.yml?query=branch:master
[coverage-image]: https://codecov.io/gh/RustCrypto/hybrid-array/graph/badge.svg?token=Z92NHFQ70G
[coverage-link]: https://codecov.io/gh/RustCrypto/hybrid-array
[license-image]: https://img.shields.io/badge/license-Apache2.0/MIT-blue.svg
[rustc-image]: https://img.shields.io/badge/rustc-1.85+-blue.svg
[chat-image]: https://img.shields.io/badge/zulip-join_chat-blue.svg
[chat-link]: https://rustcrypto.zulipchat.com/#narrow/stream/260052-utils

[//]: # (links)

[RustCrypto]: https://github.com/rustcrypto
[RustCrypto/utils#378]: https://github.com/RustCrypto/utils/issues/378
[`typenum`]: https://github.com/paholg/typenum
[`generic-array`]: https://github.com/fizyk20/generic-array
[rust-issue-60551]: https://github.com/rust-lang/rust/issues/60551
[rust-issue-76560]: https://github.com/rust-lang/rust/issues/76560
