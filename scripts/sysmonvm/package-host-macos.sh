#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
DIST_DIR="${REPO_ROOT}/dist/sysmonvm"
STAGING_DIR="${DIST_DIR}/package-macos"
OUTPUT_TAR="${DIST_DIR}/serviceradar-sysmonvm-host-macos.tar.gz"

SKIP_BUILD="${SKIP_BUILD:-0}"

if [[ "${SKIP_BUILD}" != "1" ]]; then
  make -C "${REPO_ROOT}" sysmonvm-host-build
  make -C "${REPO_ROOT}" sysmonvm-build-checker-darwin
fi

HOSTFREQ_BIN="${DIST_DIR}/mac-host/bin/hostfreq"
CHECKER_BIN="${DIST_DIR}/mac-host/bin/serviceradar-sysmon-vm"
CONFIG_JSON="${DIST_DIR}/sysmon-vm.json"
HOSTFREQ_PLIST="${REPO_ROOT}/cmd/checkers/sysmon-vm/hostmac/com.serviceradar.hostfreq.plist"
CHECKER_PLIST="${REPO_ROOT}/cmd/checkers/sysmon-vm/hostmac/com.serviceradar.sysmonvm.plist"

for path in \
  "${HOSTFREQ_BIN}" \
  "${CHECKER_BIN}" \
  "${CONFIG_JSON}" \
  "${HOSTFREQ_PLIST}" \
  "${CHECKER_PLIST}"
do
  if [[ ! -f "${path}" ]]; then
    echo "[error] missing required artifact: ${path}" >&2
    exit 1
  fi
done

rm -rf "${STAGING_DIR}"
mkdir -p \
  "${STAGING_DIR}/usr/local/libexec/serviceradar" \
  "${STAGING_DIR}/usr/local/etc/serviceradar" \
  "${STAGING_DIR}/Library/LaunchDaemons"

install -m 0755 "${HOSTFREQ_BIN}" "${STAGING_DIR}/usr/local/libexec/serviceradar/hostfreq"
install -m 0755 "${CHECKER_BIN}" "${STAGING_DIR}/usr/local/libexec/serviceradar/serviceradar-sysmon-vm"
install -m 0644 "${CONFIG_JSON}" "${STAGING_DIR}/usr/local/etc/serviceradar/sysmon-vm.json"
install -m 0644 "${HOSTFREQ_PLIST}" "${STAGING_DIR}/Library/LaunchDaemons/com.serviceradar.hostfreq.plist"
install -m 0644 "${CHECKER_PLIST}" "${STAGING_DIR}/Library/LaunchDaemons/com.serviceradar.sysmonvm.plist"

rm -f "${OUTPUT_TAR}"
tar -czf "${OUTPUT_TAR}" -C "${STAGING_DIR}" usr Library

echo "Wrote macOS host package to ${OUTPUT_TAR}"
