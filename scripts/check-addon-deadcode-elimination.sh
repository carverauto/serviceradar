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
# Native add-on dead-code-elimination guard (issue 3425, task 3.1).
#
# Go's linker marks call graph roots that force broad method retention as
# <ReflectMethod> when invoked with -ldflags=-dumpdep. Keep project-owned roots
# out of Go native add-on binaries so add-on code does not disable precise method
# dead-code elimination. This is the build-time "whydeadcode" guard from the
# proposal: if a future add-on starts calling reflect.Value/Type.Method or
# non-constant MethodByName, the linker dump explains why methods stay live and
# this gate fails closed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

MODULE_PREFIX="${MODULE_PREFIX:-github.com/carverauto/serviceradar}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/addon-deadcode.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

if ! command -v go >/dev/null 2>&1; then
  echo "error: go is required" >&2
  exit 2
fi

PKGS=()
while IFS= read -r addon_pkg; do
  [[ -n "${addon_pkg}" ]] || continue
  PKGS+=("${addon_pkg}")
done < <(go list "${MODULE_PREFIX}/go/cmd/..." 2>/dev/null | grep -E '/serviceradar-[a-z0-9-]+-addon$' || true)

if [[ ${#PKGS[@]} -eq 0 ]]; then
  echo "error: no Go native add-on command packages found" >&2
  exit 1
fi

status=0

for pkg in "${PKGS[@]}"; do
  safe_name="${pkg#${MODULE_PREFIX}/}"
  safe_name="${safe_name//\//_}"
  out_bin="${TMP_DIR}/${safe_name}"
  dump_file="${TMP_DIR}/${safe_name}.dumpdep"

  echo "CHECK linker method dead-code elimination: ${pkg}"
  if ! go build -trimpath -ldflags=-dumpdep -o "${out_bin}" "${pkg}" >"${dump_file}" 2>&1; then
    echo "  UNKNOWN go build failed" >&2
    sed 's/^/    /' "${dump_file}" >&2
    status=1
    continue
  fi

  owned_reflect_hits="$(
    grep '<ReflectMethod>' "${dump_file}" |
      grep -F -e "${MODULE_PREFIX}" -e 'main.' || true
  )"

  if [[ -n "${owned_reflect_hits}" ]]; then
    echo "  VIOLATION ${pkg} has project-owned linker <ReflectMethod> roots; method DCE is broadened" >&2
    sed 's/^/    /' <<<"${owned_reflect_hits}" | head -20 >&2
    status=1
  else
    external_count="$(grep -c '<ReflectMethod>' "${dump_file}" || true)"
    if [[ "${external_count}" == "0" ]]; then
      echo "  OK no <ReflectMethod> roots in linker dump"
    else
      echo "  OK no project-owned <ReflectMethod> roots (${external_count} external/toolchain roots observed)"
    fi
  fi
done

if ((status != 0)); then
  echo "" >&2
  echo "dead-code-elimination gate FAILED: native add-on code must not force broad" >&2
  echo "method retention. Avoid reflect.Value/Type.Method and non-constant" >&2
  echo "MethodByName in project-owned add-on binaries." >&2
  exit 1
fi

echo "dead-code-elimination gate passed"
