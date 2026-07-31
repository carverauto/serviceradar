# [RustCrypto]: Constant-Time Utilities

[![Crate][crate-image]][crate-link]
[![Docs][docs-image]][docs-link]
[![Build Status][build-image]][build-link]
![Apache 2.0/MIT Licensed][license-image]
![MSRV][msrv-image]
[![Project Chat][chat-image]][chat-link]

Constant-time utility library with selection and equality testing support targeting cryptographic
applications. Supports `const fn` where appropriate. Built on the [`cmov`] crate which provides
architecture-specific predication intrinsics. Heavily inspired by the [`subtle`] crate.

## About

This crate contains constant-time equivalents of the `bool` and `Option` types (`Choice` and
`CtOption` respectively), along with traits that can be used in combination with them.

The `CtOption` type notably provides eagerly evaluated combinator methods (as opposed to the lazily
evaluated combinators on `Option`) which make it possible to write constant-time code using
an idiomatic Rust style.

This is an experimental next-generation constant-time library inspired by `subtle`, but for now we
recommend you continue to stick with `subtle`. We may attempt to get some of the changes in this
library incorporated into `subtle` for a potential v3.0.

## What makes this crate different from `subtle`?

- Pervasive `const fn` support
  - Almost all constructors/methods on `Choice` are `const fn`
  - `Choice` can be constructed using various `const fn` predicates on integer types, enabling
    writing constant-time `const fn` logic
  - `CtOption` supports `const fn` constructors and `*_copied` methods to access the inner value
    when it's a `Copy` type
  - Macros to act as `CtOption` pseudo-combinators: `map!` and `unwrap_or!`
  - Expanded selection of `CtOption` combinators that more closely mirrors `std::option::Option`
- Guaranteed constant-time equality testing and conditional selection on `x86(_64)` and `aarch64`
  using `asm!` implementations in the `cmov` crate which call special constant-time CPU instructions
  with a portable "best effort" fallback on other platforms using bitwise arithmetic and `black_box`
- No `Copy` bounds, which means all functionality can work with heap-allocated types in addition to
  stack-allocated
- Expanded selection of traits: `CtFind` and `CtLookup` for arrays and slices

Many features of this crate are extractions from the [`crypto-bigint`] crate, where we implement all
core logic as `const fn` and needed solutions for implementing constant-time code despite the
unique constraints it imposes.

## ⚠️ Security Warning

The implementation contained in this crate has never been independently audited!

USE AT YOUR OWN RISK!

## Minimum Supported Rust Version (MSRV) Policy

MSRV increases are not considered breaking changes and can happen in patch releases.

The crate MSRV accounts for all supported targets and crate feature combinations.

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

[crate-image]: https://img.shields.io/crates/v/ctutils.svg
[crate-link]: https://crates.io/crates/ctutils
[docs-image]: https://docs.rs/ctutils/badge.svg
[docs-link]: https://docs.rs/ctutils/
[license-image]: https://img.shields.io/badge/license-Apache2.0/MIT-blue.svg
[msrv-image]: https://img.shields.io/badge/rustc-1.85+-blue.svg
[build-image]: https://github.com/RustCrypto/utils/actions/workflows/ctutils.yml/badge.svg
[build-link]: https://github.com/RustCrypto/utils/actions/workflows/ctutils.yml
[chat-image]: https://img.shields.io/badge/zulip-join_chat-blue.svg
[chat-link]: https://rustcrypto.zulipchat.com/#narrow/stream/260052-utils

[//]: # (links)

[RustCrypto]: https://github.com/RustCrypto
[`cmov`]: https://docs.rs/cmov
[`subtle`]: https://docs.rs/subtle
[`crypto-bigint`]: https://docs.rs/crypto-bigint
