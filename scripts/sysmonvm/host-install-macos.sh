#!/usr/bin/env bash
set -euo pipefail

if [[ $(id -u) -ne 0 ]]; then
  echo "[error] host-install-macos.sh must be run as root (use sudo)." >&2
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
DIST_DIR="${REPO_ROOT}/dist/sysmonvm"
HOST_BIN_DIR="${DIST_DIR}/mac-host/bin"
INSTALL_PREFIX="/usr/local/libexec/serviceradar"
CONFIG_PREFIX="/usr/local/etc/serviceradar"
HOSTFREQ_PLIST="/Library/LaunchDaemons/com.serviceradar.hostfreq.plist"
CHECKER_PLIST="/Library/LaunchDaemons/com.serviceradar.sysmonvm.plist"
LOG_DIR="/var/log/serviceradar"
CONFIG_SRC="${DIST_DIR}/sysmon-vm.json"
CONFIG_DEST="${CONFIG_PREFIX}/sysmon-vm.json"

mkdir -p "${DIST_DIR}"
make -C "${REPO_ROOT}" sysmonvm-host-build
make -C "${REPO_ROOT}" sysmonvm-build-checker-darwin

if [[ ! -f "${CONFIG_SRC}" ]]; then
  echo "[error] expected config at ${CONFIG_SRC}; run make sysmonvm-host-setup first." >&2
  exit 1
fi

install -d "${INSTALL_PREFIX}"
install -m 0755 "${HOST_BIN_DIR}/hostfreq" "${INSTALL_PREFIX}/hostfreq"
install -m 0755 "${HOST_BIN_DIR}/serviceradar-sysmon-vm" "${INSTALL_PREFIX}/serviceradar-sysmon-vm"

install -d "${CONFIG_PREFIX}"
if [[ -f "${CONFIG_DEST}" ]]; then
  install -m 0644 "${CONFIG_SRC}" "${CONFIG_DEST}.new"
  echo "[info] existing config retained at ${CONFIG_DEST}; wrote fresh template to ${CONFIG_DEST}.new"
else
  install -m 0644 "${CONFIG_SRC}" "${CONFIG_DEST}"
fi

install -d "${LOG_DIR}"
install -d "$(dirname "${HOSTFREQ_PLIST}")"
install -m 0644 "${REPO_ROOT}/cmd/checkers/sysmon-vm/hostmac/com.serviceradar.hostfreq.plist" "${HOSTFREQ_PLIST}"
install -m 0644 "${REPO_ROOT}/cmd/checkers/sysmon-vm/hostmac/com.serviceradar.sysmonvm.plist" "${CHECKER_PLIST}"

launchctl bootout system/com.serviceradar.hostfreq >/dev/null 2>&1 || true
launchctl bootout system/com.serviceradar.sysmonvm >/dev/null 2>&1 || true

launchctl bootstrap system "${HOSTFREQ_PLIST}"
launchctl bootstrap system "${CHECKER_PLIST}"
launchctl enable system/com.serviceradar.hostfreq
launchctl enable system/com.serviceradar.sysmonvm
launchctl kickstart -k system/com.serviceradar.hostfreq
launchctl kickstart -k system/com.serviceradar.sysmonvm

echo "Installed hostfreq service. Logs: ${LOG_DIR}/hostfreq.log"
echo "Installed sysmon-vm checker (macOS). Logs: ${LOG_DIR}/sysmon-vm.log"
