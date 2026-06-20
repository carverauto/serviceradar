#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  scripts/check-gazelle-drift.sh <base-ref> <head-ref>
  scripts/check-gazelle-drift.sh <go-package-dir> [<go-package-dir> ...]

Checks that Gazelle would not modify BUILD files for first-party Go package
directories. The base/head form is intended for CI and checks only Go package
directories touched by the change, so existing repository-wide Gazelle drift in
unmodified packages does not block unrelated PRs.
EOF
}

is_first_party_go_dir() {
  local dir="$1"

  [[ -d "${dir}" ]] || return 1
  [[ "${dir}" == go/* ]] || return 1
  [[ "${dir}" != go/third_party/* ]] || return 1
  [[ "${dir}" != */testdata/* ]] || return 1
  find "${dir}" -maxdepth 1 -name '*.go' -print -quit | grep -q .
}

changed_go_dirs() {
  local base_ref="$1"
  local head_ref="$2"

  git diff --name-only --diff-filter=ACMR "${base_ref}" "${head_ref}" -- go |
    while IFS= read -r path; do
      [[ "${path}" == *.go ]] || continue
      local dir
      dir="$(dirname "${path}")"
      if is_first_party_go_dir "${dir}"; then
        printf '%s\n' "${dir}"
      fi
    done |
    sort -u
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$#" -lt 1 ]]; then
  usage
  exit 2
fi

dirs=()

if [[ "$#" -eq 2 ]] && { git rev-parse --verify --quiet "$1" >/dev/null; } &&
  { git rev-parse --verify --quiet "$2" >/dev/null; }; then
  mapfile -t dirs < <(changed_go_dirs "$1" "$2")
else
  for dir in "$@"; do
    if ! is_first_party_go_dir "${dir}"; then
      echo "not a first-party Go package directory: ${dir}" >&2
      exit 2
    fi
    dirs+=("${dir}")
  done
fi

if [[ "${#dirs[@]}" -eq 0 ]]; then
  echo "No changed first-party Go package directories to check."
  exit 0
fi

echo "Checking Gazelle drift for:"
printf '  %s\n' "${dirs[@]}"

bazel run //:gazelle -- -mode=diff "${dirs[@]}"
