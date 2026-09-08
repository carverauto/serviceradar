#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${TEST_SRCDIR:-}" && -n "${TEST_WORKSPACE:-}" ]]; then
  repo_root="${TEST_SRCDIR}/${TEST_WORKSPACE}"
else
  repo_root="$(git rev-parse --show-toplevel)"
fi

source "${repo_root}/scripts/wasm-plugin-publish-context.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

metadata_dir="${tmp_dir}/metadata"
mkdir -p "${metadata_dir}"
printf '{}\n' >"${metadata_dir}/external.metadata.json"

signature_tool="${tmp_dir}/upload_signature_tool"
printf '#!/usr/bin/env bash\nexit 0\n' >"${signature_tool}"
chmod +x "${signature_tool}"

export WASM_PLUGIN_METADATA_DIR="${metadata_dir}"
export WASM_PLUGIN_UPLOAD_SIGNATURE_TOOL="${signature_tool}"
export BAZEL_BIN="${tmp_dir}/must-not-run-bazel"
printf '#!/usr/bin/env bash\nexit 97\n' >"${BAZEL_BIN}"
chmod +x "${BAZEL_BIN}"

wasm_plugin_publish_init "${repo_root}"
[[ "${WASM_PLUGIN_EXTERNAL_METADATA}" == true ]]
[[ "${METADATA_DIR}" == "$(cd "${metadata_dir}" && pwd -P)" ]]
wasm_plugin_publish_build_metadata //build/wasm_plugins:all_metadata
[[ "$(wasm_plugin_publish_resolve_upload_signature_tool)" == "${signature_tool}" ]]

if (
  export WASM_PLUGIN_METADATA_DIR="${tmp_dir}/missing"
  wasm_plugin_publish_init "${repo_root}"
) >/dev/null 2>&1; then
  echo "external publish context accepted a missing metadata directory" >&2
  exit 1
fi

if (
  export WASM_PLUGIN_METADATA_DIR="${metadata_dir}"
  unset WASM_PLUGIN_UPLOAD_SIGNATURE_TOOL
  wasm_plugin_publish_init "${repo_root}"
  wasm_plugin_publish_resolve_upload_signature_tool
) >/dev/null 2>&1; then
  echo "external publish context accepted a missing upload signature tool" >&2
  exit 1
fi

echo "external Wasm publish context contract verified"
