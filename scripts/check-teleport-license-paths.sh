#!/usr/bin/env bash
#
# Copyright 2025 Carver Automation Corporation.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

teleport_src="${TELEPORT_SRC:-$HOME/src/teleport}"
teleport_ref="${TELEPORT_REF:-}"
teleport_scan_src="$teleport_src"
teleport_worktree=""

cleanup() {
  if [[ -n "$teleport_worktree" ]]; then
    git -C "$teleport_src" worktree remove --force "$teleport_worktree" >/dev/null 2>&1 ||
      rm -rf "$teleport_worktree"
  fi
}
trap cleanup EXIT

if [[ ! -d "$teleport_src" ]]; then
  echo "Teleport source directory not found: $teleport_src" >&2
  echo "Set TELEPORT_SRC=/path/to/teleport and retry." >&2
  exit 2
fi

if [[ -n "$teleport_ref" ]]; then
  if ! git -C "$teleport_src" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Teleport source is not a git worktree: $teleport_src" >&2
    exit 2
  fi

  teleport_worktree="$(mktemp -d "${TMPDIR:-/tmp}/serviceradar-teleport-scan.XXXXXX")"
  rmdir "$teleport_worktree"
  git -C "$teleport_src" worktree add --detach --quiet "$teleport_worktree" "$teleport_ref"
  teleport_scan_src="$teleport_worktree"
fi

if ! command -v go >/dev/null 2>&1; then
  echo "go is required" >&2
  exit 2
fi

if (($# == 0)); then
  set -- \
    github.com/gravitational/teleport/api/ssh \
    github.com/gravitational/teleport/api/observability/tracing/ssh
fi

scan_dir_for_agpl() {
  local dir="$1"

  # shellcheck disable=SC2016
  find "$dir" -maxdepth 1 -type f -name '*.go' -print0 |
    xargs -0 awk '
      FNR <= 40 && ($0 ~ /GNU Affero/ || $0 ~ /AGPL/) {
        print FILENAME ":" FNR ":" $0
        found = 1
      }
      END { exit found ? 0 : 1 }
    ' 2>/dev/null || true
}

module_dir_for_import() {
  local import_path="$1"

  case "$import_path" in
    github.com/gravitational/teleport/api|github.com/gravitational/teleport/api/*)
      printf '%s/api\n' "$teleport_scan_src"
      ;;
    github.com/gravitational/teleport|github.com/gravitational/teleport/*)
      printf '%s\n' "$teleport_scan_src"
      ;;
    *)
      printf '%s\n' "$PWD"
      ;;
  esac
}

status=0

for import_path in "$@"; do
  module_dir="$(module_dir_for_import "$import_path")"

  if [[ ! -f "$module_dir/go.mod" ]]; then
    echo "UNKNOWN $import_path"
    echo "  no go.mod found for inferred module dir: $module_dir"
    status=1
    continue
  fi

  if [[ -n "$teleport_ref" ]]; then
    echo "CHECK $import_path @ $teleport_ref"
  else
    echo "CHECK $import_path"
  fi

  if ! deps="$(
    cd "$module_dir"
    go list -deps -f '{{if not .Standard}}{{.ImportPath}}{{"\t"}}{{.Dir}}{{end}}' "$import_path" 2>&1
  )"; then
    echo "  UNKNOWN go list failed"
    while IFS= read -r line; do
      echo "    $line"
    done <<<"$deps"
    status=1
    continue
  fi

  package_status=0

  while IFS=$'\t' read -r dep dep_dir; do
    [[ -n "$dep" && -n "$dep_dir" ]] || continue

    case "$dep_dir" in
      "$teleport_scan_src"/*)
        findings="$(scan_dir_for_agpl "$dep_dir")"
        if [[ -n "$findings" ]]; then
          package_status=1
          echo "  AGPL_DEP $dep"
          while IFS= read -r line; do
            echo "    $line"
          done <<<"$findings"
        fi
        ;;
    esac
  done <<<"$deps"

  if ((package_status == 0)); then
    echo "  OK no AGPL headers found in Teleport dependency directories"
  else
    status=1
  fi
done

exit "$status"
