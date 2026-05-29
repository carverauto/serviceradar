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
toolchain="${NETPROBE_EBPF_TOOLCHAIN:-nightly}"

home_dir="${HOME:-}"
if [[ -z "$home_dir" ]]; then
  home_dir="$(eval echo "~$(id -un)")"
fi

if [[ -n "$home_dir" && -d "$home_dir/.cargo/bin" ]]; then
  export PATH="$home_dir/.cargo/bin:$PATH"
fi
export PATH="/usr/local/cargo/bin:/opt/rust/cargo/bin:$PATH"

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo is required to build the netprobe eBPF object" >&2
  exit 1
fi

if ! command -v bpf-linker >/dev/null 2>&1; then
  echo "bpf-linker is required to build the netprobe eBPF object" >&2
  exit 1
fi

export CARGO_TARGET_DIR="$target_dir"
export CARGO_HOME="${CARGO_HOME:-$target_dir/cargo-home}"
export CARGO_TARGET_BPFEL_UNKNOWN_NONE_LINKER="${CARGO_TARGET_BPFEL_UNKNOWN_NONE_LINKER:-bpf-linker}"
export RUSTFLAGS="${RUSTFLAGS:-} --cfg bpf_target_arch=\"x86_64\" -C link-arg=--btf"
mkdir -p "$CARGO_HOME"

rust_sysroot="$(rustc "+$toolchain" --print sysroot)"
export LD_LIBRARY_PATH="$rust_sysroot/lib:${LD_LIBRARY_PATH:-}"
export DYLD_LIBRARY_PATH="$rust_sysroot/lib:${DYLD_LIBRARY_PATH:-}"
export DYLD_FALLBACK_LIBRARY_PATH="$rust_sysroot/lib:${DYLD_FALLBACK_LIBRARY_PATH:-}"

cargo "+$toolchain" build \
  --locked \
  --manifest-path "$manifest" \
  --target bpfel-unknown-none \
  -Z build-std=core \
  --release \
  --bin netprobe-ebpf

cp "$target_dir/bpfel-unknown-none/release/netprobe-ebpf" "$output"
