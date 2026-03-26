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

cp plugin.yaml dist/plugin.yaml
cp plugin.stream.yaml dist/plugin.stream.yaml
cp config.schema.json dist/config.schema.json
cp config.stream.schema.json dist/config.stream.schema.json

echo "Built: dist/plugin.wasm"
ls -lh dist/plugin.wasm
echo "Packaged: dist/plugin.yaml"
echo "Packaged: dist/plugin.stream.yaml"
echo "Packaged: dist/config.schema.json"
echo "Packaged: dist/config.stream.schema.json"
