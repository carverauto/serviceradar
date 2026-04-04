#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "${REPO_ROOT}"

bazel build \
  //build/wasm_plugins:axis_camera_bundle_zip \
  //build/wasm_plugins:axis_camera_bundle_sha256 \
  //build/wasm_plugins:axis_camera_stream_bundle_zip \
  //build/wasm_plugins:axis_camera_stream_bundle_sha256

BAZEL_BIN="$(bazel info bazel-bin)"

echo "Built Bazel-managed bundle artifacts:"
echo "  ${BAZEL_BIN}/build/wasm_plugins/axis_camera_bundle.zip"
echo "  ${BAZEL_BIN}/build/wasm_plugins/axis_camera_bundle.sha256"
echo "  ${BAZEL_BIN}/build/wasm_plugins/axis_camera_stream_bundle.zip"
echo "  ${BAZEL_BIN}/build/wasm_plugins/axis_camera_stream_bundle.sha256"
