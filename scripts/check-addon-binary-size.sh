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
# Per-artifact binary-size regression gate (issue 3425, task 3.1).
#
# Native add-on (and base-agent) binaries must not silently bloat. This gate
# measures each artifact's on-disk size, optionally produces a go-size-analyzer
# breakdown, and fails when a binary grows beyond a recorded baseline by more than
# a tolerance.
#
# Tooling note: go-size-analyzer (https://github.com/Zxilly/go-size-analyzer,
# binary name `gsa`) is a PREREQUISITE in the CI image. If it is not installed this
# script prints how to install it and exits 0 by default (so the gate is wired but
# does not block until the tool lands). Set REQUIRE_GSA=1 to fail closed when the
# tool is missing.
#
# Baseline workflow:
#   - The baseline JSON lives at build/native_addons/binary-size-baseline.json:
#       { "<artifact-name>": <max-bytes>, ... }
#   - For an artifact present in the baseline, exceeding the recorded byte budget
#     (after TOLERANCE_PCT) fails the gate.
#   - Artifacts absent from the baseline are reported but do not fail (run with
#     UPDATE_BASELINE=1 to seed/refresh the baseline from current sizes).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

BASELINE_FILE="${BASELINE_FILE:-build/native_addons/binary-size-baseline.json}"
TOLERANCE_PCT="${TOLERANCE_PCT:-10}"
REQUIRE_GSA="${REQUIRE_GSA:-0}"
UPDATE_BASELINE="${UPDATE_BASELINE:-0}"

GSA_BIN=""
if command -v gsa >/dev/null 2>&1; then
  GSA_BIN="gsa"
elif command -v go-size-analyzer >/dev/null 2>&1; then
  GSA_BIN="go-size-analyzer"
fi

if [[ -z "${GSA_BIN}" ]]; then
  echo "go-size-analyzer (gsa) is not installed." >&2
  echo "Install it in the CI image, e.g.:" >&2
  echo "  go install github.com/Zxilly/go-size-analyzer/cmd/gsa@latest" >&2
  if [[ "${REQUIRE_GSA}" == "1" ]]; then
    echo "REQUIRE_GSA=1 set; failing closed because the tool is missing." >&2
    exit 2
  fi
  echo "Continuing without a size breakdown (raw on-disk sizes only)." >&2
fi

if [[ "$#" -eq 0 ]]; then
  echo "error: no artifact paths supplied" >&2
  echo "usage: $0 <binary> [<binary> ...]" >&2
  echo "  e.g. $0 \$(bazel cquery --output=files //build/native_addons:all_binaries)" >&2
  exit 2
fi

file_size_bytes() {
  # Portable size in bytes (GNU stat then BSD stat).
  stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1"
}

read_baseline() {
  local name="$1"
  [[ -f "${BASELINE_FILE}" ]] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg n "${name}" '.[$n] // empty' "${BASELINE_FILE}"
  else
    # Minimal JSON read without jq: grab "name": <number>.
    grep -oE "\"${name}\"[[:space:]]*:[[:space:]]*[0-9]+" "${BASELINE_FILE}" \
      | grep -oE '[0-9]+$' || true
  fi
}

status=0
declare -A measured=()

for artifact in "$@"; do
  if [[ ! -f "${artifact}" ]]; then
    echo "error: artifact not found: ${artifact}" >&2
    status=1
    continue
  fi

  name="$(basename "${artifact}")"
  size="$(file_size_bytes "${artifact}")"
  measured["${name}"]="${size}"

  echo "SIZE ${name} = ${size} bytes"

  if [[ -n "${GSA_BIN}" ]]; then
    "${GSA_BIN}" --format text "${artifact}" 2>/dev/null | head -20 || true
  fi

  baseline="$(read_baseline "${name}" || true)"
  if [[ -z "${baseline}" ]]; then
    echo "  (no baseline for ${name}; record one with UPDATE_BASELINE=1)"
    continue
  fi

  budget=$(( baseline + baseline * TOLERANCE_PCT / 100 ))
  if (( size > budget )); then
    echo "  VIOLATION ${name} grew to ${size} bytes, exceeding baseline ${baseline} +${TOLERANCE_PCT}% (budget ${budget})" >&2
    status=1
  else
    echo "  OK within budget (baseline ${baseline}, budget ${budget})"
  fi
done

if [[ "${UPDATE_BASELINE}" == "1" ]]; then
  mkdir -p "$(dirname "${BASELINE_FILE}")"
  {
    echo "{"
    first=1
    for name in "${!measured[@]}"; do
      if (( first == 0 )); then echo ","; fi
      first=0
      printf '  "%s": %s' "${name}" "${measured[${name}]}"
    done
    echo ""
    echo "}"
  } >"${BASELINE_FILE}"
  echo "wrote baseline ${BASELINE_FILE}"
fi

if ((status != 0)); then
  echo "" >&2
  echo "binary-size regression gate FAILED" >&2
  exit 1
fi

echo "binary-size gate passed"
