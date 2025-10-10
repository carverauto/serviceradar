#!/usr/bin/env bash
# Install the sysmon-vm checker binary and configuration into the AlmaLinux VM.
#
# Usage:
#   scripts/sysmonvm/vm-install-checker.sh [--workspace <path>] [--skip-service]
#   make sysmonvm-vm-install [WORKSPACE=<path>] [SERVICE=0]

set -euo pipefail

log() {
  printf '[sysmonvm][vm-install][%s] %s\n' "$1" "${2-}"
}

die() {
  log "error" "${1-unknown error}"
  exit "${2-1}"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
default_workspace="${repo_root}/dist/sysmonvm"
workspace="${SR_SYSMONVM_WORKSPACE:-$default_workspace}"
install_service=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      shift
      [[ $# -gt 0 ]] || die "missing value for --workspace"
      workspace="$1"
      ;;
    --skip-service)
      install_service=0
      ;;
    --help|-h)
      cat <<'EOF'
Usage: vm-install-checker.sh [--workspace <path>] [--skip-service]

Copies the Linux/arm64 sysmon-vm checker into the guest, installs it under
/usr/local/bin/serviceradar-sysmon-vm, places the config at
/etc/serviceradar/checkers/sysmon-vm.json, and (unless --skip-service is set)
installs/enables the accompanying systemd unit.
EOF
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

vm_ssh="${script_dir}/vm-ssh.sh"
vm_copy="${script_dir}/vm-copy.sh"

[[ -x "${vm_ssh}" ]] || die "vm-ssh helper missing at ${vm_ssh}"
[[ -x "${vm_copy}" ]] || die "vm-copy helper missing at ${vm_copy}"

retry_vm_ssh() {
  local retries=15
  local delay=5
  local i
  for ((i=0; i<retries; i++)); do
    if "${vm_ssh}" --workspace "${workspace}" -- true >/dev/null 2>&1; then
      return 0
    fi
    sleep "${delay}"
  done
  die "unable to reach VM via SSH; ensure it is running and accessible"
}

binary_path="${workspace}/bin/serviceradar-sysmon-vm"
config_path="${workspace}/sysmon-vm.json"
service_path="${workspace}/serviceradar-sysmon-vm.service"

[[ -f "${binary_path}" ]] || die "checker binary not found at ${binary_path}; run build-checker first"
[[ -f "${config_path}" ]] || die "checker config not found at ${config_path}"
if [[ ${install_service} -eq 1 && ! -f "${service_path}" ]]; then
  die "systemd unit not found at ${service_path}; rerun host setup or copy template"
fi

retry_vm_ssh

tmp_bin="/tmp/serviceradar-sysmon-vm"
tmp_cfg="/tmp/sysmon-vm.json"
tmp_service="/tmp/serviceradar-sysmon-vm.service"

"${vm_copy}" --workspace "${workspace}" "${binary_path}" "${tmp_bin}"
"${vm_copy}" --workspace "${workspace}" "${config_path}" "${tmp_cfg}"
if [[ ${install_service} -eq 1 ]]; then
  "${vm_copy}" --workspace "${workspace}" "${service_path}" "${tmp_service}"
fi

install_script=$(cat <<'EOF'
set -euo pipefail
sudo install -d /usr/local/bin
sudo install -m 0755 /tmp/serviceradar-sysmon-vm /usr/local/bin/serviceradar-sysmon-vm
sudo install -d /etc/serviceradar/checkers
sudo install -m 0644 /tmp/sysmon-vm.json /etc/serviceradar/checkers/sysmon-vm.json
sudo rm -f /tmp/serviceradar-sysmon-vm /tmp/sysmon-vm.json
EOF
)

if [[ ${install_service} -eq 1 ]]; then
  install_script+=$'\nsudo install -m 0644 /tmp/serviceradar-sysmon-vm.service /etc/systemd/system/serviceradar-sysmon-vm.service'
  install_script+=$'\nsudo rm -f /tmp/serviceradar-sysmon-vm.service'
  install_script+=$'\nsudo systemctl daemon-reload'
  install_script+=$'\nsudo systemctl enable --now serviceradar-sysmon-vm.service'
fi

log "info" "installing checker inside VM"
printf '%s\n' "${install_script}" | "${vm_ssh}" --workspace "${workspace}" -- sudo bash -s

log "info" "installation complete"
