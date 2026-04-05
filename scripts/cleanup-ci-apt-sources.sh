#!/usr/bin/env bash

set -euo pipefail

if ! command -v apt-get >/dev/null 2>&1; then
  exit 0
fi

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  exec sudo --preserve-env=PATH bash "$0" "$@"
fi

removed=0

while IFS= read -r file; do
  [[ -f "${file}" ]] || continue

  if grep -Eq 'packages\.microsoft\.com|packagecloud\.io/github/git-lfs|ppa\.launchpadcontent\.net/git-core/ppa' "${file}"; then
    rm -f "${file}"
    removed=1
  fi
done < <(find /etc/apt -maxdepth 2 -type f \( -name '*.list' -o -name '*.sources' \) 2>/dev/null | sort)

if [[ "${removed}" -eq 1 ]]; then
  echo "Removed third-party CI APT sources from runner image."
fi
