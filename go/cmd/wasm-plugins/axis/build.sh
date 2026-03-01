#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

mkdir -p dist

echo "Building axis-camera WASM plugin..."

tinygo build \
  -o dist/plugin.wasm \
  -target=wasi \
  -gc=leaking \
  -scheduler=none \
  -no-debug \
  ./

echo "Built: dist/plugin.wasm"
ls -lh dist/plugin.wasm
