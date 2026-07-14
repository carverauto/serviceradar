# Cryptoki Rust Wrapper

<p align="center">
  <a href="https://crates.io/crates/cryptoki-sys"><img alt="Crates.io" src="https://img.shields.io/crates/v/cryptoki-sys"></a>
  <a href="https://docs.rs/cryptoki-sys"><img src="https://docs.rs/cryptoki-sys/badge.svg" alt="Code documentation"/></a>
</p>

This is the low-level wrapper crate for PKCS #11 exposing the bindgen types.

## Generating bindings

The FFI bindings presented by this crate can be either those committed in the
crate under `src/bindings` or generated on the fly from the `pkcs11.h` file
at build time. For generating the bindings at build time
please enable the `generate-bindings` feature, as it is not enabled by default.

NOTE: Only a limited set of bindings are committed and their target triplet
is included in the name of the file - if the triplet you require is not
available, feel free to raise a Pull Request to add it or to use build-time
generation of bindings. All the committed bindings **MUST** be generated from
the library version found under the `vendor` submodule.

*Copyright 2021 Contributors to the Parsec project.*
