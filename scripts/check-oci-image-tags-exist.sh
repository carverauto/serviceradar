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
  echo "usage: $0 <tag> [<tag> ...]" >&2
  exit 2
fi

if ! command -v skopeo >/dev/null 2>&1; then
  echo "skopeo is required" >&2
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

missing=0
for repository in "${repositories[@]}"; do
  for tag in "$@"; do
    if [[ -z "${tag}" ]]; then
      continue
    fi
    ref="docker://${repository}:${tag}"
    if skopeo inspect --raw "${ref}" >/dev/null 2>&1; then
      echo "found ${repository}:${tag}"
    else
      echo "missing ${repository}:${tag}" >&2
      missing=1
    fi
  done
done

exit "${missing}"
