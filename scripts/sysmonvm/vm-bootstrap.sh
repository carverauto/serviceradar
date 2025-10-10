#!/usr/bin/env bash
# Bootstrap the AlmaLinux VM with baseline packages needed for sysmon-vm.
#
# Usage:
#   scripts/sysmonvm/vm-bootstrap.sh [--workspace <path>] [--no-upgrade]
#   make sysmonvm-vm-bootstrap [WORKSPACE=<path>] [UPGRADE=0]

set -euo pipefail

log() {
  printf '[sysmonvm][vm-bootstrap][%s] %s\n' "$1" "${2-}"
}

die() {
  log "error" "${1-unknown error}"
  exit "${2-1}"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
default_workspace="${repo_root}/dist/sysmonvm"
workspace="${SR_SYSMONVM_WORKSPACE:-$default_workspace}"
perform_upgrade=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      shift
      [[ $# -gt 0 ]] || die "missing value for --workspace"
      workspace="$1"
      ;;
    --no-upgrade)
      perform_upgrade=0
      ;;
    --help|-h)
      cat <<'EOF'
Usage: vm-bootstrap.sh [--workspace <path>] [--no-upgrade]

Installs baseline tooling inside the AlmaLinux VM so the sysmon-vm checker can run natively.

Actions:
  * optional dnf -y upgrade
  * install: git, curl, jq, kernel-tools, tmux, tar, gzip, make
  * enable and start chronyd
  * verify cpupower is available
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
[[ -x "${vm_ssh}" ]] || die "vm-ssh helper missing at ${vm_ssh}"

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

run_remote() {
  log "info" "running: $*"
  "${vm_ssh}" --workspace "${workspace}" -- "$@"
}

retry_vm_ssh

if [[ ${perform_upgrade} -eq 1 ]]; then
  run_remote sudo dnf -y upgrade
else
  log "info" "skipping dnf upgrade (--no-upgrade specified)"
fi

run_remote sudo dnf -y install git curl jq kernel-tools tmux tar gzip make
run_remote sudo systemctl enable --now chronyd
run_remote 'echo 1 | sudo tee /proc/sys/kernel/perf_event_paranoid >/dev/null'
run_remote 'sudo sysctl -w kernel.perf_event_paranoid=1 >/dev/null'
run_remote sudo cpupower frequency-info >/dev/null 2>&1 || log "warn" "cpupower returned non-zero; verify cpufreq support manually"

log "info" "bootstrap complete"
