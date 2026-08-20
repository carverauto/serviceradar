#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAZEL_BIN="${BAZEL_BIN:-bazel}"
BAZEL_QUERY='attr(name, ".*_push$", //build/wasm_plugins:*)'
read -r -a BAZEL_BUILD_FLAGS <<<"${BAZEL_BUILD_FLAGS:-}"

extra_tag=""
dry_run=false

resolve_bazel_info_path() {
  local key="$1"
  shift

  local output
  if ! output="$("${BAZEL_BIN}" info "$@" "${key}" 2>&1)"; then
    printf '%s\n' "${output}" >&2
    echo "error: unable to resolve bazel info ${key}" >&2
    exit 1
  fi

  printf '%s\n' "${output}" | awk '/^\// { path = $0 } END { print path }'
}

usage() {
  cat <<'EOF'
Usage: ./scripts/push_all_wasm_plugins.sh [--tag <tag>] [--dry-run]

Environment:
  BAZEL_BIN          Bazel executable to use (default: bazel)
  BAZEL_BUILD_FLAGS  Optional flags for remote bundle builds, for example:
                     BAZEL_BUILD_FLAGS='-c opt --config=ci --stamp'
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      extra_tag="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

cd "${REPO_ROOT}"

# `mapfile` is a bash 4.0 builtin and macOS ships bash 3.2, where it does not exist
# ("mapfile: command not found"). This read loop is the portable stand-in.
push_targets=()
while IFS= read -r push_target; do
  push_targets+=("${push_target}")
done < <(
  "${BAZEL_BIN}" query "${BAZEL_QUERY}" 2>/dev/null |
    grep '^//build/wasm_plugins:' |
    LC_ALL=C sort
)

if [[ ${#push_targets[@]} -eq 0 ]]; then
  echo "error: no Bazel Wasm plugin push targets found" >&2
  exit 1
fi

remote_bazel_bin_dir=""
local_bazel_bin_dir=""
upload_signature_tool=""

if [[ ${#BAZEL_BUILD_FLAGS[@]} -gt 0 ]]; then
  remote_bazel_bin_dir="$(resolve_bazel_info_path bazel-bin "${BAZEL_BUILD_FLAGS[@]}")"

  if [[ "${dry_run}" == false ]]; then
    "${BAZEL_BIN}" build //build/wasm_plugins:upload_signature_tool >/dev/null
  fi

  local_bazel_bin_dir="$(resolve_bazel_info_path bazel-bin)"
  upload_signature_tool="${local_bazel_bin_dir}/build/wasm_plugins/upload_signature_tool_/upload_signature_tool"
fi

for target in "${push_targets[@]}"; do
  target_name="${target##*:}"
  bundle_name="${target_name%_push}"

  printf '==> %s\n' "${target}"

  if [[ ${#BAZEL_BUILD_FLAGS[@]} -gt 0 ]]; then
    build_cmd=("${BAZEL_BIN}" build "${BAZEL_BUILD_FLAGS[@]}" "//build/wasm_plugins:${bundle_name}")
    publish_cmd=(
      "${REPO_ROOT}/build/wasm_plugins/publish_plugin.sh"
      --bundle "${remote_bazel_bin_dir}/build/wasm_plugins/${bundle_name}.zip"
      --metadata "${remote_bazel_bin_dir}/build/wasm_plugins/${bundle_name}.metadata.json"
      --oras oras
      --upload-signature-tool "${upload_signature_tool}"
    )
    if [[ -n "${extra_tag}" ]]; then
      publish_cmd+=(--tag "${extra_tag}")
    fi

    printf '    '
    printf '%q ' "${build_cmd[@]}"
    printf '\n'
    printf '    '
    printf '%q ' "${publish_cmd[@]}"
    printf '\n'

    if [[ "${dry_run}" == false ]]; then
      "${build_cmd[@]}"

      if [[ ! -f "${remote_bazel_bin_dir}/build/wasm_plugins/${bundle_name}.zip" ]]; then
        echo "error: missing remote-built bundle: ${bundle_name}.zip" >&2
        exit 1
      fi
      if [[ ! -x "${upload_signature_tool}" ]]; then
        echo "error: missing local upload signature tool: ${upload_signature_tool}" >&2
        exit 1
      fi

      "${publish_cmd[@]}"
    fi
  else
    cmd=("${BAZEL_BIN}" run "${target}")
    if [[ -n "${extra_tag}" ]]; then
      cmd+=(-- --tag "${extra_tag}")
    fi

    printf '    '
    printf '%q ' "${cmd[@]}"
    printf '\n'

    if [[ "${dry_run}" == false ]]; then
      "${cmd[@]}"
    fi
  fi
done
