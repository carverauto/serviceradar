#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAZEL_BIN="${BAZEL_BIN:-bazel}"
BAZEL_CONFIG="${BAZEL_CONFIG:-remote_push}"
BAZEL_QUERY='attr(name, ".*_push$", //docker/images:*)'
HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"

extra_tag=""
dry_run=false
passthrough_args=()
bazel_bin_dir=""
darwin_crane=""
darwin_jq=""

usage() {
  cat <<'EOF'
Usage: ./scripts/push_all_images.sh [--tag <tag>] [--dry-run] [-- <oci_push args>...]

Push all publishable OCI images by running each Bazel `*_push` target sequentially.
This avoids the `rules_multirun` aggregate launcher, which is not reliable on macOS
when remote execution resolves host tools for Linux.

Options:
  --tag <tag>   Add an extra runtime tag to every image push.
  --dry-run     Print the Bazel commands without executing them.
  --help        Show this help.

Environment:
  BAZEL_BIN     Bazel executable to use (default: bazel)
  BAZEL_CONFIG  Bazel config to use for runs (default: remote_push)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      [[ $# -ge 2 ]] || { echo "error: --tag requires a value" >&2; exit 1; }
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
    --)
      shift
      passthrough_args+=("$@")
      break
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

cd "${REPO_ROOT}"

bazel_bin_dir="$("${BAZEL_BIN}" info bazel-bin 2>/dev/null | tail -n1)"

if [[ -z "${bazel_bin_dir}" || ! -d "${bazel_bin_dir}" ]]; then
  echo "error: unable to resolve bazel-bin" >&2
  exit 1
fi

resolve_darwin_tools() {
  [[ "${HOST_OS}" == "Darwin" ]] || return 0
  [[ -n "${darwin_crane}" && -n "${darwin_jq}" ]] && return 0

  local repo_suffix
  case "${HOST_ARCH}" in
    arm64|aarch64)
      repo_suffix="darwin_arm64"
      ;;
    x86_64|amd64)
      repo_suffix="darwin_amd64"
      ;;
    *)
      echo "error: unsupported macOS architecture: ${HOST_ARCH}" >&2
      exit 1
      ;;
  esac

  "${BAZEL_BIN}" build \
    "@@rules_oci++oci+oci_crane_${repo_suffix}//:crane" \
    "@@aspect_bazel_lib++toolchains+jq_${repo_suffix}//:jq" >/dev/null

  local output_base
  output_base="$("${BAZEL_BIN}" info output_base 2>/dev/null | tail -n1)"

  darwin_crane="${output_base}/external/rules_oci++oci+oci_crane_${repo_suffix}/crane"
  darwin_jq="${output_base}/external/aspect_bazel_lib++toolchains+jq_${repo_suffix}/jq"

  if [[ ! -x "${darwin_crane}" || ! -x "${darwin_jq}" ]]; then
    echo "error: failed to resolve Darwin crane/jq binaries" >&2
    exit 1
  fi
}

mapfile -t push_targets < <(
  "${BAZEL_BIN}" query "${BAZEL_QUERY}" 2>/dev/null |
    grep '^//docker/images:' |
    LC_ALL=C sort
)

if [[ ${#push_targets[@]} -eq 0 ]]; then
  echo "error: no Bazel image push targets found" >&2
  exit 1
fi

for target in "${push_targets[@]}"; do
  if [[ "${HOST_OS}" == "Darwin" ]]; then
    resolve_darwin_tools

    target_name="${target##*:}"
    build_cmd=("${BAZEL_BIN}" build "--config=${BAZEL_CONFIG}" --stamp "${target}")
    script_path="${bazel_bin_dir}/docker/images/push_${target_name}.sh"
    args=()

    if [[ -n "${extra_tag}" ]]; then
      args+=(--tag "${extra_tag}")
    fi
    if [[ ${#passthrough_args[@]} -gt 0 ]]; then
      args+=("${passthrough_args[@]}")
    fi

    printf '==> %s\n' "${target}"
    printf '    '
    printf '%q ' "${build_cmd[@]}"
    printf '\n'

    if [[ "${dry_run}" == true ]]; then
      printf '    patch CRANE=%q JQ=%q in %q and execute from %q\n' "${darwin_crane}" "${darwin_jq}" "${script_path}" "${bazel_bin_dir}"
      continue
    fi

    "${build_cmd[@]}"

    if [[ ! -f "${script_path}" ]]; then
      echo "error: missing generated push launcher: ${script_path}" >&2
      exit 1
    fi

    patched_script="$(mktemp "${TMPDIR:-/tmp}/push.${target_name}.darwin.XXXXXX")"
    cp "${script_path}" "${patched_script}"
    cleanup() {
      rm -f "${patched_script}"
    }
    trap cleanup RETURN
    perl -0pi -e \
      "s|^readonly CRANE=.*\$|readonly CRANE=\"${darwin_crane}\"|m; s|^readonly JQ=.*\$|readonly JQ=\"${darwin_jq}\"|m" \
      "${patched_script}"
    chmod +x "${patched_script}"

    (
      cd "${bazel_bin_dir}"
      "${patched_script}" "${args[@]}"
    )

    trap - RETURN
    cleanup
  else
    cmd=("${BAZEL_BIN}" run "--config=${BAZEL_CONFIG}" --stamp "${target}")

    if [[ -n "${extra_tag}" || ${#passthrough_args[@]} -gt 0 ]]; then
      cmd+=(--)
      if [[ -n "${extra_tag}" ]]; then
        cmd+=(--tag "${extra_tag}")
      fi
      if [[ ${#passthrough_args[@]} -gt 0 ]]; then
        cmd+=("${passthrough_args[@]}")
      fi
    fi

    printf '==> %s\n' "${target}"
    printf '    '
    printf '%q ' "${cmd[@]}"
    printf '\n'

    if [[ "${dry_run}" == false ]]; then
      "${cmd[@]}"
    fi
  fi
done
