#!/usr/bin/env bash
# Build the sysmon-vm checker for Linux/ARM64 and place it under dist/sysmonvm/bin.
#
# Usage:
#   scripts/sysmonvm/build-checker.sh [--workspace <path>]
#   make sysmonvm-build-checker [WORKSPACE=<path>]

set -euo pipefail

log() {
  printf '[sysmonvm][build-checker][%s] %s\n' "$1" "${2-}"
}

die() {
  log "error" "${1-unknown error}"
  exit "${2-1}"
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
      cat <<'EOF'
Usage: build-checker.sh [--workspace <path>]

Builds the sysmon-vm checker binary for Linux/arm64 and writes it to
<workspace>/bin/serviceradar-sysmon-vm.
EOF
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

output_dir="${workspace}/bin"
mkdir -p "${output_dir}"
output_bin="${output_dir}/serviceradar-sysmon-vm"

log "info" "building sysmon-vm checker into ${output_bin}"
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
  go build -trimpath -ldflags "-s -w" -o "${output_bin}" ./cmd/checkers/sysmon-vm

log "info" "build complete"
