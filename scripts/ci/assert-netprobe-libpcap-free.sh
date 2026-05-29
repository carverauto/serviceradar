#!/usr/bin/env bash
set -euo pipefail

binary="${1:-/usr/local/lib/serviceradar/bin/serviceradar-netprobe}"

if [ ! -f "${binary}" ]; then
  echo "netprobe binary not found: ${binary}" >&2
  exit 1
fi

if ! command -v ldd >/dev/null 2>&1; then
  echo "ldd is required to assert the default netprobe binary is libpcap-free" >&2
  exit 1
fi

ldd_output="$(ldd "${binary}" 2>&1 || true)"
if printf '%s\n' "${ldd_output}" | grep -q 'libpcap'; then
  echo "default netprobe binary must not link libpcap" >&2
  printf '%s\n' "${ldd_output}" >&2
  exit 1
fi

if command -v readelf >/dev/null 2>&1 && readelf -d "${binary}" >/dev/null 2>&1; then
  if readelf -d "${binary}" | grep -q 'libpcap'; then
    echo "default netprobe binary declares a libpcap dynamic dependency" >&2
    readelf -d "${binary}" >&2
    exit 1
  fi
fi

echo "netprobe binary has no libpcap dependency: ${binary}"
