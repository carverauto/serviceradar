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

set -euo pipefail

source "$(dirname "$0")/runfile_path.sh"

MAX_GLIBC_VERSION="${MAX_GLIBC_VERSION:-2.34}"

if [[ "$#" -eq 0 ]]; then
  echo "usage: $0 <native-addon-tarball-or-binary> [...]" >&2
  exit 2
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

version_gt() {
  local left="$1"
  local right="$2"
  local left_major="${left%%.*}"
  local left_minor="${left#*.}"
  local right_major="${right%%.*}"
  local right_minor="${right#*.}"

  (( left_major > right_major || (left_major == right_major && left_minor > right_minor) ))
}

inspect_binary() {
  local binary="$1"
  local label="$2"
  local versions
  local status=0

  versions="$(strings "${binary}" | grep -aoE 'GLIBC_[0-9]+\.[0-9]+' | sed 's/^GLIBC_//' | sort -Vu || true)"
  if [[ -z "${versions}" ]]; then
    echo "PORTABILITY ${label}: no GLIBC symbol versions found"
    return 0
  fi

  echo "PORTABILITY ${label}: GLIBC versions $(tr '\n' ' ' <<<"${versions}")"
  while IFS= read -r version; do
    [[ -z "${version}" ]] && continue
    if version_gt "${version}" "${MAX_GLIBC_VERSION}"; then
      echo "  VIOLATION ${label} requires GLIBC_${version}, above allowed GLIBC_${MAX_GLIBC_VERSION}" >&2
      status=1
    fi
  done <<<"${versions}"

  return "${status}"
}

inspect_artifact() {
  local artifact="$1"
  local status=0
  local name
  name="$(basename "${artifact}")"

  case "${name}" in
    *.tar.gz|*.tgz)
      local extract_dir="${tmpdir}/${name}.d"
      mkdir -p "${extract_dir}"
      tar -xzf "${artifact}" -C "${extract_dir}"
      while IFS= read -r -d '' candidate; do
        if file "${candidate}" | grep -q 'ELF .* executable'; then
          inspect_binary "${candidate}" "${name}:$(basename "${candidate}")" || status=1
        fi
      done < <(find "${extract_dir}" -type f -perm -111 -print0)
      ;;
    *)
      if file "${artifact}" | grep -q 'ELF .* executable'; then
        inspect_binary "${artifact}" "${name}" || status=1
      else
        echo "PORTABILITY ${name}: not an ELF executable, skipping"
      fi
      ;;
  esac

  return "${status}"
}

status=0
for artifact_arg in "$@"; do
  for artifact in ${artifact_arg}; do
    resolved="$(resolve_runfile "${artifact}")"
    if [[ ! -f "${resolved}" ]]; then
      echo "error: artifact not found: ${artifact}" >&2
      status=1
      continue
    fi
    inspect_artifact "${resolved}" || status=1
  done
done

if (( status != 0 )); then
  echo "" >&2
  echo "native add-on binary portability gate FAILED" >&2
  exit 1
fi

echo "native add-on binary portability gate passed"
