# `arcstr`: Better reference-counted strings.

[![Build Status](https://github.com/thomcc/arcstr/workflows/CI/badge.svg)](https://github.com/thomcc/arcstr/actions)
[![codecov](https://codecov.io/gh/thomcc/arcstr/branch/main/graph/badge.svg)](https://codecov.io/gh/thomcc/arcstr)
[![Docs](https://docs.rs/arcstr/badge.svg)](https://docs.rs/arcstr)
[![Latest Version](https://img.shields.io/crates/v/arcstr.svg)](https://crates.io/crates/arcstr)
![Minimum Rust Version](https://img.shields.io/badge/MSRV%201.57-blue.svg)

This crate defines `ArcStr`, a reference counted string type. It's essentially trying to be a better `Arc<str>` or `Arc<String>`, at least for most use cases.

ArcStr intentionally gives up some of the features of `Arc` which are rarely-used for `Arc<str>` (`Weak`, `Arc::make_mut`, ...). And in exchange, it gets a number of features that are very useful, especially for strings. Notably robust support for cheap/zero-cost `ArcStr`s holding static data (for example, string literals).

(Aside from this, it's also a single pointer, which can be good for performance and FFI)

Additionally, if the `substr` feature is enabled (and it is by default) we provide a `Substr` type which is essentially a `(ArcStr, Range<usize>)` with better ergonomics and more functionality, which represents a shared slice of a "parent" `ArcStr` (Note that in reality, `u32` is used for the index type, but this is not exposed in the API, and can be transparently changed via a cargo feature).

## Feature overview

A quick tour of the distinguishing features (note that there's a list of [benefits](https://docs.rs/arcstr/%2a/arcstr/struct.ArcStr.html#benefits-of-arcstr-over-arcstr) in the `ArcStr` documentation which covers some of the reasons you might want to use it over other alternatives). Note that it offers essentially the full set of functionality string-like functionality you probably would expect from an immutable string type — these are just the unique selling points:

```rust
use arcstr::ArcStr;
// Works in const:
const AMAZING: ArcStr = arcstr::literal!("amazing constant");
assert_eq!(AMAZING, "amazing constant");

// `arcstr::literal!` input can come from `include_str!` too:
const MY_BEST_FILES: ArcStr = arcstr::literal!(include_str!("my-best-files.txt"));
```

Or, you can define the literals in normal expressions. Note that these literals are essentially ["Zero Cost"][zero-cost]. Specifically, below we not only don't allocate any heap memory to instantiate `wow` or any of the clones, we also don't have to perform any atomic reads or writes when cloning, or dropping them (or during any other operations on them).

[zero-cost]: https://docs.rs/arcstr/%2a/arcstr/struct.ArcStr.html#what-does-zero-cost-literals-mean

```rust
let wow: ArcStr = arcstr::literal!("Wow!");
assert_eq!("Wow!", wow);
// This line is probably not something you want to do regularly,
// but as mentioned, causes no extra allocations, nor performs any
// atomic loads, stores, rmws, etc.
let wowzers = wow.clone().clone().clone().clone();

// At some point in the future, we can get a `&'static str` out of one
// of the literal `ArcStr`s too.
let static_str: Option<&'static str> = ArcStr::as_static(&wowzers);
assert_eq!(static_str, Some("Wow!"));

// Note that this returns `None` for dynamically allocated `ArcStr`:
let dynamic_arc = ArcStr::from(format!("cool {}", 123));
assert_eq!(ArcStr::as_static(&dynamic_arc), None);
```

Open TODO: Include `Substr` usage here, as it has some compelling use cases too!

## Usage

It's a normal rust crate, drop it in your `Cargo.toml`'s dependencies section. In the somewhat unlikely case that you're here and don't know how:

```toml
[dependencies]
# ...
arcstr = { version = "...", features = ["..."] }
```

The following cargo features are available. Only `substr` is on by default currently.

- `std` (off by default): Turn on to use `std::process`'s aborting, instead of triggering an abort using the "double-panic trick".

    Essentially, there's one case we need to abort, and that's during a catastrophic error where you leak the same (dynamic) `ArcStr` 2^31 on 32-bit systems, or 2^63 in 64-bit systems. If this happens, we follow `libstd`'s lead and just abort because we're hosed anyway. If `std` is enabled, we use the real `std::process::abort`. If `std` is not enabled, we trigger an `abort` by triggering a panic while another panic is unwinding, which is either defined to cause an abort, or causes one in practice.

    In pratice you will never hit this edge case, and it still works in no_std, so no_std is the default. If you have to turn this on, because you hit this ridiculous case and found our handling bad, let me know.

    Concretely, the difference here is that without this, this case becomes a call to `core::intrinsics::abort`, and not `std::process::abort`. It's a ridiculously unlikely edge case to hit, but if you are to hit it, `std::process::abort` results in a `SIGABRT` whereas `core::intrinsics::abort` results in a `SIGILL`, and the former has meaningfully better UX. That said, it's extraordinarially unlikely that you manage to leak `2^31` or `2^63` copies of the same `ArcStr`, so it's not really worth depending on `std` by default for in our opinion.

- `serde` (off by default): enable serde serialization of `ArcStr`. Note that this doesn't do any fancy deduping or whatever.

- `substr` (**on by default**): implement the `Substr` type and related functions.

- `substr-usize-indices` (off by default, implies `substr`): Use `usize` under the hood for the boundaries, instead of `u32`.

    Without this, if you use `Substr` and an index would overflow a `u32` we unceremoniously panic.

## Use of `unsafe` and testing strategy

While this crate does contain a decent amount of unsafe code, we justify this in the following ways:

1. We have a very high test coverage ratio (essentially the only uncovered functions are the out-of-memory handler (which just calls `alloc::handle_alloc_error`), and an extremely pathological integer overflow where we just abort).
2. All tests pass under various sanitizers: `asan`, `msan`, `tsan`, and `miri`.
3. We have a few [`loom`](https://crates.io/crates/loom) models although I'd love to have more.
4. Our tests pass on a ton of different targets (thanks to [`cross`](https://github.com/rust-embedded/cross/) for many of these possible — easy even):
    - Linux x86, x86_64, armv7 (arm32), aarch64 (arm64), riscv64, mips32, and mips64 (the mips32 and mips64 targets allow us to check both big-endian 32bit and 64bit. Although we don't have any endian-specific code at the moment).
    - Windows 32-bit and 64-bit, on both GNU and MSVC toolchains.
    - MacOS on x86_64.

Additionally, we test on Rust stable, beta, nightly, and our MSRV (see badge above for MSRV).

#### Supported platforms

Note that the above is *not* a list of supported platforms. In general I expect `arcstr` to support all platform's Rust supports, except for ones with `target_pointer_width="16"`, which *should* work if you turn off the `substr` feature. That said, if you'd like me to add a platform to the CI coverage to ensure it doesn't break, just ask\* (although, if it's harder than adding a line for another `cross` target, I'll probably need you to justify why it's likely to not be covered by the existing platform tests).

\* This is why there are riscv64.
