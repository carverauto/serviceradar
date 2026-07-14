[//]: # (---)

[//]: # (SPDX-License-Identifier: MIT)

[//]: # (---)

# Macros

[![Crates.io][crates-badge]][crates-url]
[![Docs.rs][docs-badge]][docs-url]
[![MIT licensed][mit-badge]][mit-url]
![Tests][test-url]

[crates-badge]: https://img.shields.io/badge/Crates.io-Latest-blue

[crates-url]: https://crates.io/crates/deep_causality_rand

[docs-badge]: https://img.shields.io/badge/Docs.rs-Latest-blue

[docs-url]: https://docs.rs/deep_causality_rand/latest/deep_causality_rand/

[mit-badge]: https://img.shields.io/badge/License-MIT-blue.svg

[mit-url]: https://github.com/deepcausality-rs/deep_causality/blob/main/LICENSE

[test-url]: https://github.com/deepcausality-rs/deep_causality/actions/workflows/run_tests.yml/badge.svg

## Why?

Custom statistics tools and distributions for the [DeepCausality project](http://www.deepcausality.com) with optional libc binding based on the [rand](https://crates.io/crates/rand) and [rand_distr](https://docs.rs/rand_distr/latest/rand_distr) crates.

**For projects other than DeepCausality, please use the excellent [rand](https://crates.io/crates/rand) and [rand_distr](https://docs.rs/rand_distr/latest/rand_distr) crates directly, as this crate is very minimalistic, lacks many common features, and does not solve any problem other than cross-compiling to targets without a libc.**

This crate provides a reduced custom implementation of the `rand` main traits and selected `rand_distr` distributions with the following properties:

* Zero external dependencies
* Zero unsafe
* Minimal macros

Among other benefits, this crate compiles with old Rust versions, easily cross-compiles on exotic hardware, compiles statically without issues, compiles even in environments without a libc, and the code is relatively easy to review. However, the minimal API is a feature to preserve the properties listed above.

## Dependencies

While this crate has no external dependencies by default, it does depend internally on the [num crate](../deep_causality_num), which itself has zero dependencies. The "os-random" feature flag introduces one optional dependency on `getrandom` and, with it, on libc. See the details below on how this crate handles libc.

## Libc

By default, this crate uses a pseudorandom number generator implemented in pure Rust; therefore, no libc is required to build. This is a deliberate decision to enable a handful of options for customization:

* Overwrite the [RngCore](../deep_causality_rand/src/traits/rng_core.rs) and [Rng trait](../deep_causality_rand/src/traits/rng.rs).
* Use the RNG from the operating system ("os-random" feature flag).
* Stick with the default PRNG (Xoshiro256).

The first option gives the most flexibility, and the existing Xoshiro256 PRNG provides a fully tested reference implementation that may serve as an example. This is most useful when multiple targets with different custom RNGs need to be supported. Nearly all operating systems expose a hardware-based random generator via libc, and when using the "os-random" feature flag, the `getrandom` crate is used to provide bindings to a large number of supported platforms. Please refer to the official [documentation for a list of platforms](https://docs.rs/getrandom/latest/getrandom). The default PRNG implementation exists mostly for testing and development, as it has similar statistical properties to a hardware-backed RNG, but, of course, it is neither secure nor should it be used in production. Instead, the default serves as an easy start with the understanding that production builds either compile with the "os-random" feature flag or use a custom implementation. This comes in handy when cross-compiling to various targets that may not have a full libc available or that use a custom hardware RNG with dedicated bindings.

## Macros

The re-implementation of the `rand` traits was done so that zero macros were used. The wisdom behind this decision boils down to the reality that macros are complex and, in general, difficult to maintain, test, and review. Therefore, the decision was made to forgo the benefits of macros and instead implement generic traits with generic types, i.e., the custom Float type from the internal [num crate](../deep_causality_num).

There are many valid reasons and use cases for macros, and, in fact, this crate does use macros to generate tests in situations where a generic trait has been implemented for many different types. However, keeping the main codebase free of macros, unsafe, and external dependencies substantially simplifies code maintenance.

## No-Std

Unfortunately, a `no-std` option is not yet supported in this first release. It can be added at some point but requires more work. If you need `no-std`, please file an issue. Alternatively, explore the `no-std` option in the [rand](https://crates.io/crates/rand) crate.

## Contributions

Contributions are welcome but must adhere to the stated goals of this crate to maintain zero macros, zero unsafe, and zero external dependencies in the main codebase (everything under the `/src` folder).

## License

This project is licensed under the [MIT license](LICENSE).

## Security

For details about security, please read the [security policy](https://github.com/deepcausality-rs/deep_causality/blob/main/SECURITY.md).

## Author

* [Marvin Hansen](https://github.com/marvin-hansen).
* Github GPG key ID: 369D5A0B210D39BC
* GPG Fingerprint: 4B18 F7B2 04B9 7A72 967E 663E 369D 5A0B 210D 39BC