#!/usr/bin/env bash
# Prepare a writable VM disk and cloud-init seed ISO for the sysmon-vm AlmaLinux guest.
#
# Usage:
#   scripts/sysmonvm/vm-create.sh [--workspace <path>] [--force]
#   make sysmonvm-vm-create [WORKSPACE=<path>]
#
# Requirements:
#   - AlmaLinux cloud image already fetched via sysmonvm-fetch-image.
#   - qemu-img, hdiutil (macOS) or genisoimage (Linux) available on PATH.

set -euo pipefail

log() {
  printf '[sysmonvm][vm-create][%s] %s\n' "$1" "${2-}"
}

die() {
  log "error" "${1-unknown error}"
  exit "${2-1}"
}

print_usage() {
  sed -n '1,80p' "${BASH_SOURCE[0]}"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
default_workspace="${repo_root}/dist/sysmonvm"
workspace="${SR_SYSMONVM_WORKSPACE:-$default_workspace}"
force=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      shift
      [[ $# -gt 0 ]] || die "missing value for --workspace"
      workspace="$1"
      ;;
    --force)
      force=1
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
[[ -f "${config_path}" ]] || die "config file not found at ${config_path}; run sysmonvm-host-setup first"

command -v qemu-img >/dev/null 2>&1 || die "qemu-img not found on PATH; install QEMU tooling first"

read_yaml_scalar() {
  local key="$1"
  local default_value="${2-__NO_DEFAULT__}"
  local value
  if value="$(ruby -ryaml -e '
require "yaml"
begin
  config = YAML.load_file(ARGV[0]) || {}
rescue Errno::ENOENT
  exit 3
end
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
  exit 4
end
' "${config_path}" "${key}")"; then
    echo "${value}"
  else
    local status=$?
    if [[ "${default_value}" != "__NO_DEFAULT__" && ${status} -eq 2 ]]; then
      echo "${default_value}"
    else
      die "missing or invalid config key '${key}' (status ${status})"
    fi
  fi
}

read_forwarded_ports() {
  ruby -ryaml -rjson -e '
require "yaml"
config = YAML.load_file(ARGV[0]) || {}
ports = config.dig("networking", "forwarded_ports")
exit 0 if ports.nil?
ports.each do |entry|
  host = entry["host"]
  guest = entry["guest"]
  next if host.nil? || guest.nil?
  puts "#{host},#{guest}"
end
' "${config_path}"
}

vm_name="$(read_yaml_scalar "vm_name")"
image_filename="$(read_yaml_scalar "image.local_filename")"
disk_size_gb="$(read_yaml_scalar "hardware.disk_size_gb")"
network_mode="$(read_yaml_scalar "networking.mode" "user")"
ssh_port="$(read_yaml_scalar "networking.ssh_port" "2222")"
cloud_hostname="$(read_yaml_scalar "cloud_init.hostname" "${vm_name}")"
cloud_user="$(read_yaml_scalar "cloud_init.user" "alma")"
ssh_key_path_raw="$(read_yaml_scalar "cloud_init.ssh_authorized_key_path" "${HOME}/.ssh/id_ed25519.pub")"
passwordless_sudo="$(read_yaml_scalar "cloud_init.enable_passwordless_sudo" "true")"

if [[ "${network_mode}" != "user" ]]; then
  die "networking.mode '${network_mode}' not supported yet (only 'user')"
fi

ssh_key_path="${ssh_key_path_raw/#\~/$HOME}"
[[ -f "${ssh_key_path}" ]] || die "SSH public key not found at ${ssh_key_path}"
ssh_pub="$(<"${ssh_key_path}")"

images_dir="${workspace}/images"
cloud_init_dir="${workspace}/cloud-init/${vm_name}"
mkdir -p "${images_dir}" "${cloud_init_dir}"

base_image="${images_dir}/${image_filename}"
[[ -f "${base_image}" ]] || die "base image not found at ${base_image}; run sysmonvm-fetch-image first"

vm_disk="${images_dir}/${vm_name}.qcow2"
seed_iso="${workspace}/cloud-init/${vm_name}-cidata.iso"

if [[ -f "${vm_disk}" && ${force} -eq 0 ]]; then
  die "vm disk ${vm_disk} already exists; remove it or re-run with --force"
fi

if [[ -f "${vm_disk}" ]]; then
  log "info" "removing existing vm disk ${vm_disk}"
  rm -f "${vm_disk}"
fi

log "info" "creating qcow2 overlay ${vm_disk} (size ${disk_size_gb}G)"
qemu-img create -f qcow2 -F qcow2 -b "${base_image}" "${vm_disk}" "${disk_size_gb}G" >/dev/null

user_data="${cloud_init_dir}/user-data"
meta_data="${cloud_init_dir}/meta-data"

log "info" "writing cloud-init user-data to ${user_data}"
{
  echo "#cloud-config"
  echo "hostname: ${cloud_hostname}"
  echo "fqdn: ${cloud_hostname}"
  echo "manage_etc_hosts: true"
  echo "users:"
  echo "  - default"
  echo "  - name: ${cloud_user}"
  echo "    gecos: ${cloud_user}"
  echo "    groups: [wheel, docker]"
  echo "    shell: /bin/bash"
  if [[ "${passwordless_sudo}" == "true" ]]; then
    echo "    sudo: [\"ALL=(ALL) NOPASSWD:ALL\"]"
  else
    echo "    sudo: [\"ALL=(ALL) ALL\"]"
  fi
  echo "    ssh_authorized_keys:"
  echo "      - ${ssh_pub}"
  echo "package_update: true"
  echo "package_upgrade: true"
  echo "timezone: UTC"
} > "${user_data}"

log "info" "writing cloud-init meta-data to ${meta_data}"
{
  echo "instance-id: ${vm_name}-$(date +%Y%m%d%H%M%S)"
  echo "local-hostname: ${cloud_hostname}"
} > "${meta_data}"

if [[ -f "${seed_iso}" && ${force} -eq 0 ]]; then
  die "seed ISO ${seed_iso} already exists; remove it or re-run with --force"
fi

[[ -f "${seed_iso}" ]] && rm -f "${seed_iso}"

log "info" "building cloud-init seed ISO ${seed_iso}"
seed_root="${seed_iso%.*}"
tmp_base="${seed_root}-tmp"
tmp_iso="${tmp_base}.iso"
rm -f "${tmp_base}" "${tmp_iso}" "${seed_iso}.tmp" "${seed_iso}.tmp.iso"
if command -v hdiutil >/dev/null 2>&1; then
  hdiutil makehybrid -iso -joliet -default-volume-name cidata "${cloud_init_dir}" -o "${tmp_base}" >/dev/null
  if [[ -f "${tmp_iso}" ]]; then
    :
  elif [[ -f "${tmp_base}.cdr" ]]; then
    mv "${tmp_base}.cdr" "${tmp_iso}"
  else
    die "failed to produce cloud-init ISO via hdiutil"
  fi
elif command -v genisoimage >/dev/null 2>&1; then
  genisoimage -output "${tmp_iso}" -volid cidata -joliet -rock "${cloud_init_dir}" >/dev/null
else
  die "neither hdiutil nor genisoimage is available to create the cloud-init ISO"
fi
mv "${tmp_iso}" "${seed_iso}"
rm -f "${tmp_base}"

log "info" "forwarded ports:"
log "info" "  host tcp/${ssh_port} -> guest 22 (SSH)"
if ports=$(read_forwarded_ports) && [[ -n "${ports}" ]]; then
  while IFS=',' read -r host guest; do
    [[ -z "${host}" || -z "${guest}" ]] && continue
    log "info" "  host tcp/${host} -> guest ${guest}"
  done <<< "${ports}"
fi

cat <<EOF

VM provisioning assets created:
  disk:   ${vm_disk}
  seed:   ${seed_iso}
  cloud:  ${cloud_init_dir}/user-data

Proceed with 'make sysmonvm-vm-start' to boot the VM.
EOF
