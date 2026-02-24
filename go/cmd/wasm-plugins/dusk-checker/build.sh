#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Output directory
mkdir -p dist

echo "Building dusk-checker WASM plugin..."

# Build with TinyGo
# - gc=leaking: Required for stable WASM execution (no GC pauses)
# - scheduler=none: Single-threaded execution model for WASM
# - target=wasi: WebAssembly System Interface target
tinygo build \
    -o dist/plugin.wasm \
    -target=wasi \
    -gc=leaking \
    -scheduler=none \
    -no-debug \
    ./

echo "Built: dist/plugin.wasm"
ls -lh dist/plugin.wasm
