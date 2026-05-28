#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <Cargo.toml> <output-object>" >&2
  exit 2
fi

manifest="$1"
output="$2"
target_dir="$(mktemp -d "${TMPDIR:-/tmp}/serviceradar-netprobe-ebpf.XXXXXX")"
trap 'rm -rf "$target_dir"' EXIT

export CARGO_TARGET_DIR="$target_dir"
export CARGO_TARGET_BPFEL_UNKNOWN_NONE_LINKER="${CARGO_TARGET_BPFEL_UNKNOWN_NONE_LINKER:-bpf-linker}"
export RUSTFLAGS="${RUSTFLAGS:-} --cfg bpf_target_arch=\"x86_64\" -C link-arg=--btf"

cargo +nightly build \
  --locked \
  --manifest-path "$manifest" \
  --target bpfel-unknown-none \
  -Z build-std=core \
  --release \
  --bin netprobe-ebpf

cp "$target_dir/bpfel-unknown-none/release/netprobe-ebpf" "$output"
