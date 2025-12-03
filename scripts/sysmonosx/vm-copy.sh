#!/usr/bin/env bash
# Copy a local file into the AlmaLinux VM workspace using the config metadata.
#
# Usage:
#   scripts/sysmonvm/vm-copy.sh [--workspace <path>] <local_path> <remote_path>
#   make sysmonvm-vm-copy SRC=local/file DEST=/tmp/remote.file

set -euo pipefail

log() {
  printf '[sysmonvm][vm-copy][%s] %s\n' "$1" "${2-}"
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
      shift
      ;;
    --help|-h)
      cat <<'EOF'
Usage: vm-copy.sh [--workspace <path>] <local_file> <remote_path>

Copies a local file into the running sysmon-vm guest via scp, creating the remote
parent directory if needed. Use absolute remote paths (e.g. /tmp/foo).
EOF
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

[[ $# -eq 2 ]] || die "expected <local_file> and <remote_path> arguments"
local_path="$1"
remote_path="$2"

[[ -f "${local_path}" ]] || die "local file not found: ${local_path}"

config_path="${workspace}/config.yaml"
[[ -f "${config_path}" ]] || die "config file not found at ${config_path}"

read_yaml_scalar() {
  local key="$1"
  ruby -ryaml -e '
require "yaml"
config = YAML.load_file(ARGV[0]) || {}
path = ARGV[1].split(".")
cursor = config
path.each do |segment|
  if cursor.is_a?(Hash)
    cursor = cursor[segment]
  else
    cursor = nil
  end
end
if cursor.nil?
  exit 1
end
puts cursor
' "${config_path}" "${key}"
}

ssh_port="$(read_yaml_scalar "networking.ssh_port" 2>/dev/null || echo "2222")"
cloud_user="$(read_yaml_scalar "cloud_init.user" 2>/dev/null || echo "alma")"

metadata_dir="${workspace}/metadata"
mkdir -p "${metadata_dir}"
known_hosts_file="${metadata_dir}/ssh_known_hosts"

remote_dir="$(dirname "${remote_path}")"

"${script_dir}/vm-ssh.sh" --workspace "${workspace}" -- mkdir -p "${remote_dir}"

scp -P "${ssh_port}" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile="${known_hosts_file}" \
  "${local_path}" \
  "${cloud_user}@127.0.0.1:${remote_path}"

log "info" "copied ${local_path} to ${remote_path}"
