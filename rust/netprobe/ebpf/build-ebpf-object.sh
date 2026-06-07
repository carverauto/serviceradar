#!/usr/bin/env bash
# Hermetic netprobe eBPF object build.
#
# Every toolchain input is passed in explicitly — a pinned nightly Rust toolchain
# (rustc/cargo/rust-std/rust-src component archives assembled into a scratch
# sysroot), a pinned static `bpf-linker`, and a vendored crate tree — so the build
# touches NO system `PATH` tooling and runs offline. This is what makes it correct
# under Bazel remote execution (RBE), where no Rust toolchain or network exists.
#
# See openspec/changes/add-hermetic-netprobe-ebpf-build/ for the pins + rationale.
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: build-ebpf-object.sh --output <path> --bpf-linker <bin> --vendor <dir> \
                            --crate <ebpf-crate-dir> \
                            --install <component-install.sh> [--install ...]
USAGE
  exit 2
}

output=""
bpf_linker=""
vendor=""
crate=""
installs=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --bpf-linker) bpf_linker="$2"; shift 2 ;;
    --vendor) vendor="$2"; shift 2 ;;
    --crate) crate="$2"; shift 2 ;;
    --install) installs+=("$2"); shift 2 ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

[[ -n "$output" && -n "$bpf_linker" && -n "$vendor" && -n "$crate" ]] || usage
[[ ${#installs[@]} -gt 0 ]] || { echo "at least one --install required" >&2; usage; }

# Resolve everything to absolute paths up front (we cd around below).
abspath() { (cd "$(dirname "$1")" >/dev/null 2>&1 && printf '%s/%s' "$(pwd)" "$(basename "$1")"); }
bpf_linker="$(abspath "$bpf_linker")"
vendor="$(abspath "$vendor")"
crate="$(abspath "$crate")"
output_dir="$(cd "$(dirname "$output")" >/dev/null 2>&1 && pwd)"
output="${output_dir}/$(basename "$output")"

target_triple="bpfel-unknown-none"
host_triple="${NETPROBE_EBPF_HOST_TRIPLE:-x86_64-unknown-linux-gnu}"

work="$(mktemp -d "${TMPDIR:-/tmp}/serviceradar-netprobe-ebpf.XXXXXX")"
trap 'rm -rf "$work"' EXIT
prefix="$work/toolchain"
mkdir -p "$prefix"

# 1. Assemble the nightly sysroot from the pinned rustup-dist component archives.
#    Each archive root carries an install.sh that merges its component into --prefix.
for inst in "${installs[@]}"; do
  inst="$(abspath "$inst")"
  bash "$inst" \
    --prefix="$prefix" \
    --disable-ldconfig >/dev/null 2>"$work/install.err" || {
      echo "component install failed: $inst" >&2; cat "$work/install.err" >&2; exit 1; }
done

cargo_bin="$prefix/bin/cargo"
rustc_bin="$prefix/bin/rustc"
[[ -x "$cargo_bin" && -x "$rustc_bin" ]] || { echo "assembled toolchain missing cargo/rustc" >&2; ls -R "$prefix/bin" >&2 || true; exit 1; }
# build-std needs the std sources in the sysroot.
[[ -d "$prefix/lib/rustlib/src/rust/library/core" ]] || { echo "rust-src not present in sysroot (need it for -Z build-std)" >&2; exit 1; }

# 2. Stage the eBPF crate as its own isolated workspace pointed at the vendored deps.
src="$work/ebpf"
mkdir -p "$src"
cp "$crate/Cargo.toml" "$crate/Cargo.lock" "$src/"
cp -R "$crate/src" "$src/src"
[[ -d "$crate/include" ]] && cp -R "$crate/include" "$src/include"
printf '\n[workspace]\n' >> "$src/Cargo.toml"  # isolate from any parent workspace
mkdir -p "$src/.cargo"
cat > "$src/.cargo/config.toml" <<EOF
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "$vendor"
EOF

# 3. Build the eBPF object offline with build-std + the BPF linker.
export PATH="$prefix/bin:/usr/bin:/bin"
export CARGO_HOME="$work/cargo-home"
export RUSTC="$rustc_bin"
export CARGO_TARGET_DIR="$work/target"
export LD_LIBRARY_PATH="$prefix/lib:${LD_LIBRARY_PATH:-}"
export CARGO_TARGET_BPFEL_UNKNOWN_NONE_LINKER="$bpf_linker"
export RUSTFLAGS="--cfg bpf_target_arch=\"x86_64\" -C link-arg=--btf"
mkdir -p "$CARGO_HOME"

# cargo discovers .cargo/config.toml (the vendored-source replacement) from the
# working directory upward — so build from inside the staged crate.
cd "$src"
"$cargo_bin" build \
  --offline \
  --locked \
  --target "$target_triple" \
  -Z build-std=core \
  --release \
  --bin netprobe-ebpf

cp "$CARGO_TARGET_DIR/$target_triple/release/netprobe-ebpf" "$output"
echo "wrote $output"
