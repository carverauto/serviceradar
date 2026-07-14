#!/usr/bin/env bash

# Copyright 2022 Contributors to the Parsec project.
# SPDX-License-Identifier: Apache-2.0

set -xeuf -o pipefail
TARGET_DIR=${CARGO_TARGET_DIR:-../target}
find "$TARGET_DIR" -name "pkcs11_bindings.rs" -delete
MAKE_GENERIC_BINDINGS=1 cargo build --features generate-bindings
find "$TARGET_DIR" -name "pkcs11_bindings.rs" | xargs -I '{}' cp '{}' src/bindings/generic.rs

targets="aarch64-unknown-linux-gnu arm-unknown-linux-gnueabi loongarch64-unknown-linux-gnu x86_64-pc-windows-msvc i686-unknown-linux-gnu powerpc64-unknown-linux-gnu riscv64gc-unknown-linux-gnu x86_64-unknown-linux-gnu x86_64-apple-darwin aarch64-apple-darwin x86_64-unknown-freebsd"
TARGET_INSTALLED=

for target in $targets; do

    # Check if the target is already installed
    if ! rustup target list | grep -q "$target (installed)"; then
        rustup target install "$target"
        TARGET_INSTALLED="$target"
    fi

    cargo build --target "$target" --features generate-bindings
    find "$TARGET_DIR"/"$target"/ -name "pkcs11_bindings.rs" | xargs -I '{}' cp '{}' src/bindings/"$target".rs

    if [ "$TARGET_INSTALLED" == "$target" ]; then
        rustup target remove "$target"
    fi
done
