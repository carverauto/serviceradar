#!/usr/bin/env bash
# Remove generated VM assets (overlay disk and cloud-init seed ISO).
#
# Usage:
#   scripts/sysmonvm/vm-destroy.sh [--workspace <path>] [--yes]
#   make sysmonvm-vm-destroy [WORKSPACE=<path>]

set -euo pipefail

log() {
  printf '[sysmonvm][vm-destroy][%s] %s\n' "$1" "${2-}"
}

die() {
  log "error" "${1-unknown error}"
  exit "${2-1}"
}

print_usage() {
  sed -n '1,60p' "${BASH_SOURCE[0]}"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
default_workspace="${repo_root}/dist/sysmonvm"
workspace="${SR_SYSMONVM_WORKSPACE:-$default_workspace}"
assume_yes=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      shift
      [[ $# -gt 0 ]] || die "missing value for --workspace"
      workspace="$1"
      ;;
    --yes|-y)
      assume_yes=1
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

config_path="${workspace}/config.yaml"
[[ -f "${config_path}" ]] || die "config file not found at ${config_path}"

vm_name="$(ruby -ryaml -e '
require "yaml"
config = YAML.load_file(ARGV[0]) || {}
value = config["vm_name"]
if value.nil? || value.empty?
  exit 1
end
puts value
' "${config_path}")" || die "failed to determine vm_name from config"

vm_disk="${workspace}/images/${vm_name}.qcow2"
seed_iso="${workspace}/cloud-init/${vm_name}-cidata.iso"
cloud_init_dir="${workspace}/cloud-init/${vm_name}"
metadata_dir="${workspace}/metadata"
logs_dir="${workspace}/logs"
monitor_socket="${metadata_dir}/${vm_name}.monitor"
vars_file="${metadata_dir}/${vm_name}.vars.fd"
serial_log="${logs_dir}/${vm_name}.serial.log"

targets=()
[[ -f "${vm_disk}" ]] && targets+=("${vm_disk}")
[[ -f "${seed_iso}" ]] && targets+=("${seed_iso}")
[[ -d "${cloud_init_dir}" ]] && targets+=("${cloud_init_dir}")
[[ -S "${monitor_socket}" ]] && targets+=("${monitor_socket}")
[[ -f "${vars_file}" ]] && targets+=("${vars_file}")
[[ -f "${serial_log}" ]] && targets+=("${serial_log}")

if [[ ${#targets[@]} -eq 0 ]]; then
  log "info" "no generated VM assets found; nothing to clean"
  exit 0
fi

log "info" "the following assets will be removed:"
for item in "${targets[@]}"; do
  log "info" "  ${item}"
done

if [[ ${assume_yes} -eq 0 ]]; then
  read -r -p "Proceed with deletion? [y/N] " reply
  case "${reply}" in
    [yY][eE][sS]|[yY]) ;;
    *) log "info" "aborted"; exit 0 ;;
  esac
fi

for item in "${targets[@]}"; do
  rm -rf "${item}"
  log "info" "removed ${item}"
done

log "info" "cleanup complete"
