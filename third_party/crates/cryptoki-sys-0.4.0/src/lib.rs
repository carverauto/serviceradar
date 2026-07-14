// Copyright 2021,2023 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
#![allow(non_upper_case_globals)]
#![allow(non_camel_case_types)]
#![allow(non_snake_case)]
#![allow(clippy::redundant_field_names)]
#![allow(clippy::missing_safety_doc)]
#![allow(clippy::string_lit_as_bytes)]
#![allow(clippy::too_many_arguments)]
// Public items exportedby this crate should match the C style
#![allow(clippy::upper_case_acronyms)]
// Suppress warnings from bindgen-generated code
// Remove on resolution of
// https://github.com/rust-lang/rust-bindgen/issues/1651
#![allow(deref_nullptr)]

// For supported targets: use the generated and committed bindings.
#[cfg(all(
    not(feature = "generate-bindings"),
    target_arch = "x86_64",
    target_os = "linux"
))]
include!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/src/bindings/x86_64-unknown-linux-gnu.rs"
));

#[cfg(all(
    not(feature = "generate-bindings"),
    target_arch = "x86",
    target_os = "linux"
))]
include!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/src/bindings/i686-unknown-linux-gnu.rs"
));

#[cfg(all(
    not(feature = "generate-bindings"),
    target_arch = "powerpc64",
    target_os = "linux"
))]
include!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/src/bindings/powerpc64-unknown-linux-gnu.rs"
));

#[cfg(all(
    not(feature = "generate-bindings"),
    target_arch = "aarch64",
    target_os = "linux"
))]
include!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/src/bindings/aarch64-unknown-linux-gnu.rs"
));

#[cfg(all(
    not(feature = "generate-bindings"),
    target_arch = "arm",
    target_os = "linux"
))]
include!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/src/bindings/arm-unknown-linux-gnueabi.rs"
));

#[cfg(all(
    not(feature = "generate-bindings"),
    target_arch = "loongarch64",
    target_os = "linux"
))]
include!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/src/bindings/loongarch64-unknown-linux-gnu.rs"
));

#[cfg(all(
    not(feature = "generate-bindings"),
    target_arch = "riscv64",
    target_os = "linux"
))]
include!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/src/bindings/riscv64gc-unknown-linux-gnu.rs"
));

#[cfg(all(
    not(feature = "generate-bindings"),
    target_arch = "x86_64",
    target_os = "macos"
))]
include!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/src/bindings/x86_64-apple-darwin.rs"
));

#[cfg(all(
    not(feature = "generate-bindings"),
    target_arch = "aarch64",
    target_os = "macos"
))]
include!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/src/bindings/aarch64-apple-darwin.rs"
));

#[cfg(all(
    not(feature = "generate-bindings"),
    target_arch = "x86_64",
    target_os = "windows"
))]
include!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/src/bindings/x86_64-pc-windows-msvc.rs"
));

#[cfg(all(
    not(feature = "generate-bindings"),
    target_arch = "x86_64",
    target_os = "freebsd"
))]
include!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/src/bindings/x86_64-unknown-freebsd.rs"
));

// For supported targets: use the generated and committed bindings.
#[cfg(not(any(
    feature = "generate-bindings",
    all(target_arch = "x86_64", target_os = "linux"),
    all(target_arch = "x86", target_os = "linux"),
    all(target_arch = "powerpc64", target_os = "linux"),
    all(target_arch = "aarch64", target_os = "linux"),
    all(target_arch = "arm", target_os = "linux"),
    all(target_arch = "loongarch64", target_os = "linux"),
    all(target_arch = "riscv64", target_os = "linux"),
    all(target_arch = "x86_64", target_os = "macos"),
    all(target_arch = "aarch64", target_os = "macos"),
    all(target_arch = "x86_64", target_os = "windows"),
    all(target_arch = "x86_64", target_os = "freebsd"),
)))]
include!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/src/bindings/generic.rs"
));

// If the "generate-bindings" feature is on, use the generated bindings.
#[cfg(feature = "generate-bindings")]
include!(concat!(env!("OUT_DIR"), "/pkcs11_bindings.rs"));

// bindgen generates u64::MAX value for ~0UL macro definition, it's not valid on 32bit ulong platforms.
// This is a workaround for that.
pub const CK_UNAVAILABLE_INFORMATION: CK_ULONG = CK_ULONG::MAX;
