#!/usr/bin/env bash

# Shared metadata/tool resolution for first-party Wasm publication scripts.
# Monorepo callers retain the Bazel-backed defaults. External plugin release
# workflows provide an already-built metadata directory and signature tool.

wasm_plugin_publish_init() {
  local repo_root="$1"

  BAZEL_BIN="${BAZEL_BIN:-bazel}"
  WASM_PLUGIN_EXTERNAL_METADATA=false

  if [[ -n "${WASM_PLUGIN_METADATA_DIR:-}" ]]; then
    if [[ ! -d "${WASM_PLUGIN_METADATA_DIR}" ]]; then
      echo "error: Wasm plugin metadata directory does not exist: ${WASM_PLUGIN_METADATA_DIR}" >&2
      return 1
    fi

    METADATA_DIR="$(cd "${WASM_PLUGIN_METADATA_DIR}" && pwd -P)"
    BAZEL_BIN_DIR="${BAZEL_BIN_DIR:-}"
    WASM_PLUGIN_EXTERNAL_METADATA=true
    return 0
  fi

  BAZEL_BIN_DIR="${BAZEL_BIN_DIR:-$("${BAZEL_BIN}" info bazel-bin 2>/dev/null)}"
  if [[ -z "${BAZEL_BIN_DIR}" ]]; then
    echo "error: unable to resolve Bazel output directory" >&2
    return 1
  fi

  METADATA_DIR="${BAZEL_BIN_DIR}/build/wasm_plugins"
  REPO_ROOT="${repo_root}"
}

wasm_plugin_publish_build_metadata() {
  if [[ "${WASM_PLUGIN_EXTERNAL_METADATA}" == true ]]; then
    return 0
  fi

  "${BAZEL_BIN}" build "$@" >/dev/null
}

wasm_plugin_publish_resolve_upload_signature_tool() {
  local candidate=""

  if [[ "${WASM_PLUGIN_EXTERNAL_METADATA}" == true ]]; then
    candidate="${WASM_PLUGIN_UPLOAD_SIGNATURE_TOOL:-}"
    if [[ -z "${candidate}" ]]; then
      echo "error: WASM_PLUGIN_UPLOAD_SIGNATURE_TOOL is required with external metadata" >&2
      return 1
    fi
  else
    candidate="$(
      "${BAZEL_BIN}" cquery --output=files \
        //build/wasm_plugins:upload_signature_tool 2>/dev/null | head -n1
    )"
    if [[ -n "${candidate}" && ! -x "${candidate}" && -x "${BAZEL_BIN_DIR}/${candidate}" ]]; then
      candidate="${BAZEL_BIN_DIR}/${candidate}"
    fi
    if [[ -z "${candidate}" || ! -x "${candidate}" ]]; then
      candidate="$(
        find "${BAZEL_BIN_DIR}/build/wasm_plugins" \
          -type f -name upload_signature_tool -perm -111 2>/dev/null | head -n1
      )"
    fi
  fi

  if [[ -n "${candidate}" && "${candidate}" != */* ]]; then
    candidate="$(command -v "${candidate}" 2>/dev/null || true)"
  fi
  if [[ -z "${candidate}" || ! -x "${candidate}" ]]; then
    echo "error: unable to resolve upload signature tool binary" >&2
    return 1
  fi

  printf '%s\n' "${candidate}"
}
