#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_HOME="${HOME}"

if command -v asdf >/dev/null 2>&1 && asdf exec cargo --version >/dev/null 2>&1; then
  export ASDF_DIR="${ASDF_DIR:-$REAL_HOME/.asdf}"
  export ASDF_DATA_DIR="${ASDF_DATA_DIR:-$REAL_HOME/.asdf}"
  CARGO_CMD=(asdf exec cargo)
elif command -v cargo >/dev/null 2>&1; then
  CARGO_CMD=(cargo)
else
  echo "cargo not found (install Rust or asdf)." >&2
  exit 1
fi

if [ "$#" -gt 0 ]; then
  MANIFESTS=("$@")
else
  MANIFESTS=(
    "Cargo.toml"
    "web-ng/native/srql_nif/Cargo.toml"
  )
fi

TMP_HOME="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_HOME"
}
trap cleanup EXIT

export CARGO_HOME="$TMP_HOME/.cargo"

for manifest in "${MANIFESTS[@]}"; do
  if [ ! -f "$ROOT_DIR/$manifest" ]; then
    echo "Cargo.toml not found at $manifest" >&2
    exit 1
  fi
  "${CARGO_CMD[@]}" fetch --locked --manifest-path "$ROOT_DIR/$manifest"
done

tar -C "$TMP_HOME" -czf "$ROOT_DIR/build/cargo_cache.tar.gz" .cargo
echo "Updated $ROOT_DIR/build/cargo_cache.tar.gz"
