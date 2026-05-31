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
# Add-on dependency-isolation CI gate (issue 3425, task 3.2).
#
# Asserts that the base serviceradar-agent binary's transitive Go package set does
# NOT include any add-on *implementation* package, so an add-on can never be linked
# into the base agent. Add-ons run as supervised out-of-process go-plugin
# subprocesses; only the agent-side contract/manager packages
# (go/pkg/addon, go/pkg/agent/addon, proto/agent/addon/v1) are allowed in the agent.
#
# Implementation packages that MUST stay out of the base agent:
#   - the add-on authoring SDK: github.com/.../go/pkg/addon/sdk
#   - every add-on command:     github.com/.../go/cmd/serviceradar-*-addon (and subpkgs)
#
# The gate runs `go list -deps` on the agent main package, scans the transitive set
# for any forbidden package, and fails with the offending import path when violated.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

MODULE_PREFIX="${MODULE_PREFIX:-github.com/carverauto/serviceradar}"

# Base binaries whose transitive deps must exclude add-on implementation code.
AGENT_PKGS=(
  "${MODULE_PREFIX}/go/cmd/agent"
)

# Patterns (extended regex, anchored) describing forbidden add-on implementation
# packages. The agent-side contract packages are intentionally NOT listed here.
FORBIDDEN_PATTERNS=(
  "^${MODULE_PREFIX}/go/pkg/addon/sdk(/.*)?$"
  "^${MODULE_PREFIX}/go/cmd/serviceradar-[a-z0-9-]+-addon(/.*)?$"
)

if ! command -v go >/dev/null 2>&1; then
  echo "error: go is required" >&2
  exit 2
fi

status=0

for agent_pkg in "${AGENT_PKGS[@]}"; do
  echo "CHECK base package transitive deps: ${agent_pkg}"

  if ! deps="$(go list -deps "${agent_pkg}" 2>&1)"; then
    echo "  UNKNOWN go list failed" >&2
    while IFS= read -r line; do
      echo "    ${line}" >&2
    done <<<"${deps}"
    status=1
    continue
  fi

  pkg_status=0

  while IFS= read -r dep; do
    [[ -n "${dep}" ]] || continue

    for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
      if [[ "${dep}" =~ ${pattern} ]]; then
        echo "  VIOLATION ${agent_pkg} transitively imports add-on implementation package: ${dep}" >&2
        pkg_status=1
      fi
    done
  done <<<"${deps}"

  if ((pkg_status == 0)); then
    echo "  OK no add-on implementation package in the base agent's transitive set"
  else
    status=1
  fi
done

if ((status != 0)); then
  echo "" >&2
  echo "add-on dependency-isolation gate FAILED: the base agent must never link add-on" >&2
  echo "implementation code. Add-ons run as supervised out-of-process subprocesses." >&2
  exit 1
fi

echo "add-on dependency-isolation gate passed"
