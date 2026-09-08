#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "${REPO_ROOT}"

bazel build \
  //build/wasm_plugins:hello_wasm_bundle_zip \
  //build/wasm_plugins:hello_wasm_bundle_sha256 \
  //build/wasm_plugins:hello_wasm_bundle_metadata

BAZEL_BIN="$(bazel info bazel-bin)"

echo "Built Bazel-managed bundle artifacts:"
echo "  ${BAZEL_BIN}/build/wasm_plugins/hello_wasm_bundle.zip"
echo "  ${BAZEL_BIN}/build/wasm_plugins/hello_wasm_bundle.sha256"
echo "  ${BAZEL_BIN}/build/wasm_plugins/hello_wasm_bundle.metadata.json"
