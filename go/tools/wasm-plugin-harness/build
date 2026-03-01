#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT_DIR="$ROOT_DIR/dist"

TINYGO_BIN="${TINYGO_BIN:-tinygo}"
if ! command -v "$TINYGO_BIN" >/dev/null 2>&1; then
  echo "tinygo is required but not installed (missing: $TINYGO_BIN)." >&2
  echo "Install tinygo and re-run this script." >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

"$TINYGO_BIN" build -tags=tinygo -target=wasi -o "$OUT_DIR/plugin.wasm" "$ROOT_DIR/main.go"

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$OUT_DIR/plugin.wasm" | awk '{print $1}' > "$OUT_DIR/plugin.wasm.sha256"
else
  shasum -a 256 "$OUT_DIR/plugin.wasm" | awk '{print $1}' > "$OUT_DIR/plugin.wasm.sha256"
fi

echo "Built: $OUT_DIR/plugin.wasm"
