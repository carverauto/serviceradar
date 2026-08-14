//! Version anchor for the protoc plugins the Bazel prost toolchain runs.
//!
//! This crate deliberately has no code. Its `Cargo.toml` is the whole point: it makes
//! `protoc-gen-prost`, `protoc-gen-tonic` and `prost-types` dependencies of a real workspace
//! member, which is the only way they reach the Bazel build graph now that crate resolution
//! goes through `//:Cargo.lock` alone. See `//build/rust/prost_toolchain`.
