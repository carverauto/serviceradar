# Core Error

With the recent proliferation of error-handling crates, it has become clear that
the situation around the lack of a `core::error::Error` is really suboptimal. In
`snafu`, `no_std` support is being introduced through a whole new Error trait
just for `no_std` - which could lead to similar problems that `failure` had by
becoming incompatible with the ecosystem.

Ideally, the `Error` trait would show up in core, but due to coherence concerns
and std-dependent features being added to `std::error::Error`, a resolution is
unlikely to happen soon.  As such, I propose making a new crate, `core-error` -
exposing our own version of the `Error `trait. The goal of this crate is
twofolds:

- Provide a common trait for various error handling crates (Failure, Snafu,
  Fehler, Anyhow, error_chain, and any others?)
- Allow no_std libraries that don't want to depend on a specific error handling
  crate to still expose errors that can interoperate with those libraries.

This crate is still in the early stages. Once it reaches 1.0.0, it will be ready
for integration in the various error crates. Furthermore, once it reaches 1.0.0,
it will follow the same stability guarantees Rust does.

# Minimum Rust Version

This crate works all the way down to 1.0.0. It auto-detects the Rust version in
order to know which error structs to implement the trait on.

With `no-default-features`, the crate only compiles from 1.6.0 onwards (version
at which `no_std` became stable).