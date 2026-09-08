#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

release_file="${SERVICERADAR_NETPROBE_KERNEL_RELEASE_FILE:-}"
if [[ -z "${release_file}" && "${SERVICERADAR_NETPROBE_SIMULATE_OLD_KERNEL:-}" = "1" ]]; then
  release_file="$(mktemp "${TMPDIR:-/tmp}/serviceradar-netprobe-kernel.XXXXXX")"
  trap 'rm -f "${release_file}"' EXIT
  printf '5.4.0-ci\n' > "${release_file}"
fi

if [[ -n "${release_file}" ]]; then
  export SERVICERADAR_NETPROBE_KERNEL_RELEASE_FILE="${release_file}"
fi

output="$(
  sfw cargo run \
    -p serviceradar-netprobe \
    --no-default-features \
    --bin netprobe-kernel-check \
    -- --expect-unavailable
)"
printf '%s\n' "${output}"

grep -q 'host-network-visibility=unavailable' <<<"${output}"
grep -q 'reason=kernel_too_old' <<<"${output}"
