#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -n "${SERVICERADAR_REPO_ROOT:-}" ]]; then
  REPO_ROOT="$(cd "${SERVICERADAR_REPO_ROOT}" && pwd)"
elif REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  REPO_ROOT="$(cd "${script_dir}/.." && pwd)"
fi

INVENTORY="${SERVICERADAR_IMAGE_INVENTORY:-${REPO_ROOT}/docker/images/image_inventory.bzl}"

if [[ ! -r "${INVENTORY}" ]]; then
  echo "image inventory is not readable: ${INVENTORY}" >&2
  exit 2
fi

if [[ $# -eq 0 ]]; then
  echo "usage: $0 <canonical-tag> [<matching-tag> ...]" >&2
  exit 2
fi

oci_helper=""
for candidate in \
  "${script_dir}/oci_registry.sh" \
  "${GITHUB_WORKSPACE:-}/scripts/oci_registry.sh"; do
  if [[ -f "${candidate}" ]]; then
    oci_helper="${candidate}"
    break
  fi
done
if [[ -z "${oci_helper}" ]]; then
  echo "oci_registry.sh not found" >&2
  exit 2
fi
# shellcheck source=scripts/oci_registry.sh
source "${oci_helper}"
if ! command -v oras >/dev/null 2>&1; then
  echo "oras is required" >&2
  exit 2
fi

mapfile -t repositories < <(
  python3 - "$INVENTORY" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
for repo in re.findall(r'"repository"\s*:\s*"([^"]+)"', text):
    print(repo)
PY
)

if [[ ${#repositories[@]} -eq 0 ]]; then
  echo "no publishable image repositories found in ${INVENTORY}" >&2
  exit 2
fi

canonical_tag="$1"
shift

needs_publish=0
for repository in "${repositories[@]}"; do
  if ! canonical_digest="$(oci_registry_digest "${repository}:${canonical_tag}" 2>/tmp/oci-inspect.err)"; then
    if grep -Eiq 'manifest unknown|name unknown|not found|not exist' /tmp/oci-inspect.err; then
      echo "missing ${repository}:${canonical_tag}" >&2
      needs_publish=1
      continue
    fi

    echo "failed to inspect ${repository}:${canonical_tag}: $(cat /tmp/oci-inspect.err)" >&2
    exit 2
  fi
  if [[ ! "${canonical_digest}" =~ ^sha256:[[:xdigit:]]{64}$ ]]; then
    echo "invalid digest returned for ${repository}:${canonical_tag}: ${canonical_digest}" >&2
    exit 2
  fi
  echo "found ${repository}:${canonical_tag} at ${canonical_digest}"

  for tag in "$@"; do
    [[ -n "${tag}" ]] || continue

    if ! digest="$(oci_registry_digest "${repository}:${tag}" 2>/tmp/oci-inspect.err)"; then
      if grep -Eiq 'manifest unknown|name unknown|not found|not exist' /tmp/oci-inspect.err; then
        echo "missing ${repository}:${tag}" >&2
        needs_publish=1
        continue
      fi

      echo "failed to inspect ${repository}:${tag}: $(cat /tmp/oci-inspect.err)" >&2
      exit 2
    fi
    if [[ ! "${digest}" =~ ^sha256:[[:xdigit:]]{64}$ ]]; then
      echo "invalid digest returned for ${repository}:${tag}: ${digest}" >&2
      exit 2
    fi
    if [[ "${digest}" != "${canonical_digest}" ]]; then
      echo "mismatched ${repository}:${tag}: ${digest} (expected ${canonical_digest})" >&2
      needs_publish=1
      continue
    fi

    echo "matched ${repository}:${tag} at ${digest}"
  done
done

exit "${needs_publish}"
