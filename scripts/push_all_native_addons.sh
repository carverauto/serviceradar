#!/usr/bin/env bash
# Runs every native add-on _push target (build/native_addons/defs.bzl), publishing
# each bundle's OCI artifact. Mirrors scripts/push_all_wasm_plugins.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAZEL_BIN="${BAZEL_BIN:-bazel}"
BAZEL_QUERY='attr(name, ".*_push$", //build/native_addons:*)'
read -r -a BAZEL_BUILD_FLAGS <<<"${BAZEL_BUILD_FLAGS:--c opt}"

extra_tag=""
dry_run=false

usage() {
  cat <<'EOF'
Usage: ./scripts/push_all_native_addons.sh [--tag <tag>] [--dry-run]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) extra_tag="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

cd "${REPO_ROOT}"

mapfile -t push_targets < <(
  "${BAZEL_BIN}" query "${BAZEL_QUERY}" 2>/dev/null |
    grep '^//build/native_addons:' |
    LC_ALL=C sort
)

if [[ ${#push_targets[@]} -eq 0 ]]; then
  echo "error: no Bazel native add-on push targets found" >&2
  exit 1
fi

for target in "${push_targets[@]}"; do
  cmd=("${BAZEL_BIN}" run "${BAZEL_BUILD_FLAGS[@]}" "${target}")
  if [[ -n "${extra_tag}" ]]; then
    cmd+=(-- --tag "${extra_tag}")
  fi

  printf '==> %s\n' "${target}"
  printf '    '
  printf '%q ' "${cmd[@]}"
  printf '\n'

  if [[ "${dry_run}" == false ]]; then
    "${cmd[@]}"
  fi
done
