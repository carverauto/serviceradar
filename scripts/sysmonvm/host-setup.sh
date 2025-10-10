#!/usr/bin/env bash
# Host preparation workflow for the sysmon-vm checker prototype.
#
# This script automates the key tasks from Phase 1 of cpu_plan.md:
#   * ensure required tooling (qemu, wget, sha256sum/coreutils, Go >= 1.22)
#   * verify Hypervisor.framework availability on macOS
#   * provision a workspace for VM artifacts (disk images, cloud-init configs)
#   * stage the default VM configuration template
#
# Usage:
#   scripts/sysmonvm/host-setup.sh [--workspace <path>]
#
# Environment variables:
#   SR_SYSMONVM_WORKSPACE - Alternative workspace location, overrides default.

set -euo pipefail

log() {
  printf '[sysmonvm][%s] %s\n' "$1" "${2-}"
}

die() {
  log "error" "${1-unknown error}"
  exit "${2-1}"
}

print_usage() {
  cat <<'EOF'
Usage: host-setup.sh [--workspace <path>] [--help]

Options:
  --workspace <path>  Directory for VM artifacts (defaults to dist/sysmonvm)
  --help              Show this help message and exit

Environment:
  SR_SYSMONVM_WORKSPACE  Overrides the default workspace location.

The script installs the host prerequisites for running the AlmaLinux VM that
will execute the sysmon-vm checker, and prepares a workspace seeded with the
default configuration template.
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
default_workspace="${repo_root}/dist/sysmonvm"
workspace="${SR_SYSMONVM_WORKSPACE:-$default_workspace}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      shift
      [[ $# -gt 0 ]] || die "missing value for --workspace"
      workspace="$1"
      ;;
    --help|-h)
      print_usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

mkdir -p "${workspace}"

uname_s="$(uname -s)"
case "${uname_s}" in
  Darwin)
    log "info" "detected macOS host"
    command -v brew >/dev/null 2>&1 || die "Homebrew is required; install from https://brew.sh/"

    # Packages required for Phase 1.
    brew_packages=(
      qemu
      wget
      coreutils
    )

    for pkg in "${brew_packages[@]}"; do
      if brew ls --versions "${pkg}" >/dev/null 2>&1; then
        log "info" "Homebrew package '${pkg}' already installed"
      else
        log "info" "installing Homebrew package '${pkg}'"
        brew install "${pkg}" || die "failed to install ${pkg} via Homebrew"
      fi
    done
    ;;
  Linux)
    log "warn" "Linux host detected; automated package installation not implemented"
    log "warn" "please install qemu, wget, and coreutils manually before continuing"
    ;;
  *)
    die "unsupported host OS: ${uname_s}"
    ;;
esac

# Verify Go toolchain and version.
if command -v go >/dev/null 2>&1; then
  go_version="$(go version | awk '{print $3}' | sed 's/go//')"
  required_major=1
  required_minor=22
  IFS='.' read -r major minor _ <<<"${go_version}"
  major=${major:-0}
  minor=${minor:-0}
  if [[ "${major}" -lt "${required_major}" ]] || { [[ "${major}" -eq "${required_major}" ]] && [[ "${minor}" -lt "${required_minor}" ]]; }; then
    log "warn" "Go ${go_version} detected; please upgrade to >= 1.22 for sysmon-vm development"
  else
    log "info" "Go ${go_version} meets minimum version requirements"
  fi
else
  case "${uname_s}" in
    Darwin)
      log "info" "Go toolchain not found; installing via Homebrew"
      brew install go || die "failed to install go via Homebrew"
      ;;
    *)
      log "warn" "Go toolchain not found; install Go >= 1.22 manually"
      ;;
  esac
fi

# macOS-specific virtualisation check.
if [[ "${uname_s}" == "Darwin" ]]; then
  if sysctl -q kern.hv_support >/dev/null 2>&1; then
    hvf_supported="$(sysctl -n kern.hv_support)"
    if [[ "${hvf_supported}" != "1" ]]; then
      log "warn" "Hypervisor.framework support is disabled; QEMU acceleration may be unavailable"
    else
      log "info" "Hypervisor.framework acceleration (hvf) is available"
    fi
  else
    log "warn" "Unable to read kern.hv_support; ensure virtualization is enabled in macOS settings"
  fi
fi

# Prepare workspace layout.
for dir in images cloud-init logs metadata; do
  mkdir -p "${workspace}/${dir}"
done
log "info" "workspace initialized at ${workspace}"

# Seed configuration template if available.
config_template="${repo_root}/tools/sysmonvm/config.example.yaml"
config_target="${workspace}/config.yaml"
if [[ -f "${config_template}" ]]; then
  if [[ -f "${config_target}" ]]; then
    log "info" "configuration file already present at ${config_target}"
  else
    cp "${config_template}" "${config_target}"
    log "info" "copied default config template to ${config_target}"
  fi
else
  log "warn" "config template not found at ${config_template}; skipping copy"
fi

mkdir -p "${workspace}/bin"

checker_cfg_template="${repo_root}/tools/sysmonvm/sysmon-vm.json"
checker_cfg_target="${workspace}/sysmon-vm.json"
if [[ -f "${checker_cfg_template}" ]]; then
  if [[ -f "${checker_cfg_target}" ]]; then
    log "info" "checker config already present at ${checker_cfg_target}"
  else
    cp "${checker_cfg_template}" "${checker_cfg_target}"
    log "info" "seeded sysmon-vm checker config at ${checker_cfg_target}"
  fi
else
  log "warn" "checker config template not found at ${checker_cfg_template}"
fi

service_template="${repo_root}/tools/sysmonvm/serviceradar-sysmon-vm.service"
service_target="${workspace}/serviceradar-sysmon-vm.service"
if [[ -f "${service_template}" ]]; then
  if [[ -f "${service_target}" ]]; then
    log "info" "systemd unit already present at ${service_target}"
  else
    cp "${service_template}" "${service_target}"
    log "info" "copied systemd service template to ${service_target}"
  fi
else
  log "warn" "systemd service template not found at ${service_template}"
fi

# Emit final summary.
cat <<EOF

Host preparation complete.

Next steps:
  1. Review ${config_target} and adjust VM sizing or networking as needed.
  2. Proceed to Phase 2 in cpu_plan.md to download the AlmaLinux cloud image.
EOF
