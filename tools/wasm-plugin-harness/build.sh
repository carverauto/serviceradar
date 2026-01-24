#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT_DIR="$ROOT_DIR/dist"

if ! command -v tinygo >/dev/null 2>&1; then
  echo "tinygo is required but not installed." >&2
  echo "Install tinygo and re-run this script." >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

tinygo build -tags=tinygo -target=wasi -o "$OUT_DIR/plugin.wasm" "$ROOT_DIR/main.go"

sha256sum "$OUT_DIR/plugin.wasm" | awk '{print $1}' > "$OUT_DIR/plugin.wasm.sha256"

echo "Built: $OUT_DIR/plugin.wasm"
