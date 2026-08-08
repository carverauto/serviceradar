# [RustCrypto]: CMOV (Conditional Move)

[![Crate][crate-image]][crate-link]
[![Docs][docs-image]][docs-link]
[![Build Status][build-image]][build-link]
![Apache 2.0/MIT Licensed][license-image]
![MSRV][msrv-image]
[![Project Chat][chat-image]][chat-link]

Conditional move CPU intrinsics which are guaranteed on major platforms to execute in constant-time
and not be rewritten as branches by the compiler.

Provides wrappers for the [CMOV family] of instructions on `x86`/`x86_64` and the [CSEL]
instruction on `aarch64` CPUs, along with a portable fallback implementation for other CPU
architectures.

## About

Conditional move intrinsics provide [predication] which allows selection
of one or more values without using branch instructions, thus making the
selection constant-time with respect to the values, and not subject to CPU
execution features which might introduce timing or other microarchitectural
sidechannels introduced by branch prediction or other speculative execution
features.

This crate provides wrappers for the CMOV/CSEL instructions implemented using
inline `asm!`, which means the implementation is a black box that will not be
rewritten by e.g. LLVM's architecture-specific lowerings, such as the
[x86-cmov-conversion] pass.

This is a *low level crate* who's API is designed to make it easy to build
portable abstractions across various CPU architectures and is not intended for
general purpose use.

See the [`ctutils`] crate for a higher-level API build on top of `cmov`.

## Supported target architectures

This crate provides guaranteed constant-time operation using inline `asm!`
on the following CPU architectures:

- [x] `x86`/`x86_64` (`CMOVZ`, `CMOVNZ`)
- [x] `arm` (mask generation only)
- [x] `aarch64` (`CSEL`)
- [x] `riscv32` (mask generation only)
- [x] `riscv64` (mask generation only)

On other target architectures, a "best effort" portable fallback implementation
based on bitwise arithmetic is used instead, augmented with tactical usage of
`core::hint::black_box` based on past analysis of the generated assembly.
However, we cannot guarantee that this implementation generates branch-free
code, especially on hypothetical future rustc versions which introduce new
optimizations.

Please [open an issue] if you notice non-constant-time CPU instructions
(e.g. branches, secret-dependent address calculations) being generated and we
will treat it as a security issue and do our best to find a solution.

You can also open an issue to request first-class support for native
predication instructions on other architectures we don't currently support.

### `x86` / `x86_64` notes

Intel has confirmed that all extant CPUs implement the CMOV family of
instructions in constant-time, and that this property will hold for future
Intel CPUs as well.

## ⚠️ Security Warning

The implementation contained in this crate has never been independently audited!
USE AT YOUR OWN RISK!

Below are security issues this crate has experienced in the past:

- [RUSTSEC-2026-0003]: Non-constant-time code generation on ARM32 targets
- [GHSA-3rjw-m598-pq24]: `Cmov`/`CmovEq` on ARM64 can produce wrong results if high-bits of registers are set

## Minimum Supported Rust Version (MSRV) Policy

MSRV increases are not considered breaking changes and can happen in patch
releases.

The crate MSRV accounts for all supported targets and crate feature
combinations, excluding explicitly unstable features.

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

[crate-image]: https://img.shields.io/crates/v/cmov.svg
[crate-link]: https://crates.io/crates/cmov
[docs-image]: https://docs.rs/cmov/badge.svg
[docs-link]: https://docs.rs/cmov/
[license-image]: https://img.shields.io/badge/license-Apache2.0/MIT-blue.svg
[msrv-image]: https://img.shields.io/badge/rustc-1.85+-blue.svg
[build-image]: https://github.com/RustCrypto/utils/actions/workflows/cmov.yml/badge.svg
[build-link]: https://github.com/RustCrypto/utils/actions/workflows/cmov.yml
[chat-image]: https://img.shields.io/badge/zulip-join_chat-blue.svg
[chat-link]: https://rustcrypto.zulipchat.com/#narrow/stream/260052-utils

[//]: # (links)

[RustCrypto]: https://github.com/RustCrypto
[CMOV family]: https://www.jaist.ac.jp/iscenter-new/mpc/altix/altixdata/opt/intel/vtune/doc/users_guide/mergedProjects/analyzer_ec/mergedProjects/reference_olh/mergedProjects/instructions/instruct32_hh/vc35.htm
[CSEL]: https://developer.arm.com/documentation/dui0802/b/CSEL
[predication]: https://en.wikipedia.org/wiki/Predication_(computer_architecture)
[x86-cmov-conversion]: https://dsprenkels.com/cmov-conversion.html
[`ctutils`]: https://docs.rs/ctutils
[open an issue]: https://github.com/RustCrypto/utils/issues
[RUSTSEC-2026-0003]: https://rustsec.org/advisories/RUSTSEC-2026-0003.html
[GHSA-3rjw-m598-pq24]: https://github.com/RustCrypto/utils/security/advisories/GHSA-3rjw-m598-pq24
