#!/usr/bin/env bash
#
# Copyright 2026 Carver Automation Corporation.
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
#
# Build-hygiene gate (issue 3425, task 3.1): forbid the Go stdlib `plugin` package.
#
# Native ServiceRadar add-ons run as supervised out-of-process go-plugin
# (hashicorp/go-plugin) subprocesses, NOT via the Go stdlib `plugin` package
# (dlopen-style shared objects). The stdlib `plugin` package disables dead-code
# elimination, bloats binaries, and is fragile across toolchains, so it must never
# appear in the agent or any add-on build.
#
# This gate is authoritative: it uses `go list -deps` to compute the transitive
# package set of the base agent and of every add-on command, and fails if the
# stdlib `plugin` package is reachable from any of them. It additionally performs a
# precise source-level grep for a `plugin` import statement (not string literals)
# across the agent and add-on package trees as defense-in-depth.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

MODULE_PREFIX="${MODULE_PREFIX:-github.com/carverauto/serviceradar}"

if ! command -v go >/dev/null 2>&1; then
  echo "error: go is required" >&2
  exit 2
fi

# Build the list of packages to audit: the base agent plus every add-on command.
PKGS=("${MODULE_PREFIX}/go/cmd/agent")

while IFS= read -r addon_pkg; do
  [[ -n "${addon_pkg}" ]] || continue
  PKGS+=("${addon_pkg}")
done < <(go list "${MODULE_PREFIX}/go/cmd/..." 2>/dev/null | grep -E '/serviceradar-[a-z0-9-]+-addon$' || true)

status=0

for pkg in "${PKGS[@]}"; do
  echo "CHECK transitive deps for stdlib plugin: ${pkg}"

  if ! deps="$(go list -deps "${pkg}" 2>&1)"; then
    echo "  UNKNOWN go list failed" >&2
    while IFS= read -r line; do
      echo "    ${line}" >&2
    done <<<"${deps}"
    status=1
    continue
  fi

  if grep -qx "plugin" <<<"${deps}"; then
    echo "  VIOLATION ${pkg} transitively imports the Go stdlib 'plugin' package" >&2
    status=1
  else
    echo "  OK no stdlib plugin in transitive set"
  fi
done

# Defense-in-depth: enumerate every package under the agent + add-on source trees
# and assert none DIRECTLY imports the stdlib `plugin` package. This uses
# `go list` import metadata (authoritative) rather than grepping source, so it is
# immune to string-literal false positives (e.g. `return "plugin"` or map keys).
echo "CHECK direct imports of stdlib plugin in agent/add-on packages"

SOURCE_TREES=(
  "${MODULE_PREFIX}/go/cmd/agent/..."
  "${MODULE_PREFIX}/go/pkg/agent/..."
  "${MODULE_PREFIX}/go/pkg/addon/..."
  "${MODULE_PREFIX}/go/cmd/..."
)

direct_hits=""
while IFS= read -r line; do
  [[ -n "${line}" ]] || continue
  pkg="${line%% *}"
  imports=" ${line#* } "
  if [[ "${imports}" == *" plugin "* ]]; then
    direct_hits+="${pkg}"$'\n'
  fi
done < <(go list -f '{{.ImportPath}} {{join .Imports " "}}' "${SOURCE_TREES[@]}" 2>/dev/null | sort -u || true)

if [[ -n "${direct_hits}" ]]; then
  echo "  VIOLATION the following package(s) directly import the Go stdlib 'plugin' package:" >&2
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    echo "    ${line}" >&2
  done <<<"${direct_hits}"
  status=1
else
  echo "  OK no package directly imports stdlib plugin"
fi

if ((status != 0)); then
  echo "" >&2
  echo "stdlib-plugin gate FAILED: the Go stdlib 'plugin' package is forbidden in the" >&2
  echo "agent and add-on builds. Native add-ons use hashicorp/go-plugin subprocesses." >&2
  exit 1
fi

echo "stdlib-plugin gate passed"
