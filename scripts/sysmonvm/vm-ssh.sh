#!/usr/bin/env bash
# Convenience wrapper to SSH into the sysmon-vm guest using workspace config.
#
# Usage:
#   scripts/sysmonvm/vm-ssh.sh [--workspace <path>] [-- user-command]
#   make sysmonvm-vm-ssh [WORKSPACE=<path>] [ARGS="command"]

set -euo pipefail

log() {
  printf '[sysmonvm][vm-ssh][%s] %s\n' "$1" "${2-}"
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
Usage: vm-ssh.sh [--workspace <path>] [-- user-command]
Connects to the AlmaLinux VM defined in the workspace configuration.

Examples:
  scripts/sysmonvm/vm-ssh.sh                # open interactive shell
  scripts/sysmonvm/vm-ssh.sh -- sudo dnf update -y
EOF
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

config_path="${workspace}/config.yaml"
[[ -f "${config_path}" ]] || die "config file not found at ${config_path}"

read_yaml_scalar() {
  local key="$1"
  local default_value="${2-__NO_DEFAULT__}"
  local value
  if value="$(ruby -ryaml -e '
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
  exit 2
end
if cursor.is_a?(TrueClass) || cursor.is_a?(FalseClass)
  puts(cursor ? "true" : "false")
elsif cursor.is_a?(Numeric)
  puts(cursor)
elsif cursor.is_a?(String)
  puts(cursor)
else
  exit 3
end
' "${config_path}" "${key}")"; then
    echo "${value}"
  else
    local status=$?
    if [[ "${default_value}" != "__NO_DEFAULT__" && ${status} -eq 2 ]]; then
      echo "${default_value}"
    else
      die "missing or invalid config key '${key}'"
    fi
  fi
}

ssh_port="$(read_yaml_scalar "networking.ssh_port" "2222")"
cloud_user="$(read_yaml_scalar "cloud_init.user" "alma")"

metadata_dir="${workspace}/metadata"
mkdir -p "${metadata_dir}"
known_hosts_file="${metadata_dir}/ssh_known_hosts"

ssh_args=(
  ssh
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile="${known_hosts_file}"
  -p "${ssh_port}"
  "${cloud_user}@127.0.0.1"
)

if [[ $# -gt 0 ]]; then
  ssh_args+=("$@")
fi

exec "${ssh_args[@]}"
