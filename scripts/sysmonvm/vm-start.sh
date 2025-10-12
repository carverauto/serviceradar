#!/usr/bin/env bash
# Launch the AlmaLinux VM for the sysmon-vm checker.
#
# Usage:
#   scripts/sysmonvm/vm-start.sh [--workspace <path>] [--no-headless]
#   make sysmonvm-vm-start [WORKSPACE=<path>]
#
# By default the VM boots headless (`-nographic`) with serial output bound
# to the current terminal. Press Ctrl+A then X to exit QEMU.

set -euo pipefail

log() {
  printf '[sysmonvm][vm-start][%s] %s\n' "$1" "${2-}"
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
headless=1
daemonize=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      shift
      [[ $# -gt 0 ]] || die "missing value for --workspace"
      workspace="$1"
      ;;
    --no-headless)
      headless=0
      ;;
    --daemonize)
      daemonize=1
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

command -v qemu-system-aarch64 >/dev/null 2>&1 || die "qemu-system-aarch64 not found on PATH"
command -v qemu-img >/dev/null 2>&1 || die "qemu-img not found on PATH"

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
  exit 4
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

read_forwarded_ports() {
  ruby -ryaml -e '
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
cpu_count="$(read_yaml_scalar "hardware.cpu_count")"
memory_mb="$(read_yaml_scalar "hardware.memory_mb")"
accelerator="$(read_yaml_scalar "hardware.accelerator" "hvf")"
network_mode="$(read_yaml_scalar "networking.mode" "user")"
ssh_port="$(read_yaml_scalar "networking.ssh_port" "2222")"

if [[ "${network_mode}" != "user" ]]; then
  die "networking.mode '${network_mode}' not supported yet"
fi

images_dir="${workspace}/images"
vm_disk="${images_dir}/${vm_name}.qcow2"
seed_iso="${workspace}/cloud-init/${vm_name}-cidata.iso"

[[ -f "${images_dir}/${image_filename}" ]] || die "base image ${images_dir}/${image_filename} not found (run sysmonvm-fetch-image)"
[[ -f "${vm_disk}" ]] || die "VM disk ${vm_disk} not found (run sysmonvm-vm-create)"
[[ -f "${seed_iso}" ]] || die "cloud-init seed ISO ${seed_iso} not found (run sysmonvm-vm-create)"

logs_dir="${workspace}/logs"
metadata_dir="${workspace}/metadata"
mkdir -p "${logs_dir}" "${metadata_dir}"
serial_log="${logs_dir}/${vm_name}.serial.log"
monitor_socket="${metadata_dir}/${vm_name}.monitor"
vars_file="${metadata_dir}/${vm_name}.vars.fd"

find_firmware_file() {
  local filename="$1"
  local -a candidates=(
    "/opt/homebrew/share/qemu/${filename}"
    "/usr/local/share/qemu/${filename}"
    "/usr/share/qemu/${filename}"
    "/usr/share/edk2-${filename%.*}/${filename}"
    "/usr/share/edk2/${filename}"
  )
  for path in "${candidates[@]}"; do
    if [[ -f "${path}" ]]; then
      echo "${path}"
      return 0
    fi
  done
  if command -v brew >/dev/null 2>&1; then
    local brew_prefix
    brew_prefix="$(brew --prefix qemu 2>/dev/null || true)"
    if [[ -n "${brew_prefix}" && -f "${brew_prefix}/share/qemu/${filename}" ]]; then
      echo "${brew_prefix}/share/qemu/${filename}"
      return 0
    fi
  fi
  return 1
}

firmware_code="$(find_firmware_file "edk2-aarch64-code.fd")" || die "could not locate edk2-aarch64-code.fd; install QEMU firmware"
firmware_vars_template="$(find_firmware_file "edk2-arm-vars.fd")" || die "could not locate edk2-arm-vars.fd; install QEMU firmware"

if [[ ! -f "${vars_file}" ]]; then
  cp "${firmware_vars_template}" "${vars_file}"
fi

rm -f "${monitor_socket}"
rm -f "${serial_log}"

hostfwd_opts="hostfwd=tcp::${ssh_port}-:22"
if ports=$(read_forwarded_ports); then
  while IFS=',' read -r host guest; do
    [[ -z "${host}" || -z "${guest}" ]] && continue
    hostfwd_opts+=",hostfwd=tcp::${host}-:${guest}"
  done <<< "${ports}"
fi

qemu_cmd=(
  qemu-system-aarch64
  -name "${vm_name}"
  -machine "virt,accel=${accelerator}"
  -cpu host
  -smp "${cpu_count}"
  -m "${memory_mb}"
  -drive "file=${vm_disk},if=virtio,format=qcow2"
  -cdrom "${seed_iso}"
  -nic "user,model=virtio-net-pci,${hostfwd_opts}"
  -drive "if=pflash,format=raw,readonly=on,file=${firmware_code}"
  -drive "if=pflash,format=raw,file=${vars_file}"
)

if [[ ${daemonize} -eq 1 ]]; then
  qemu_cmd+=(-daemonize -serial "file:${serial_log}" -monitor "unix:${monitor_socket},server,nowait")
  if [[ ${headless} -eq 1 ]]; then
    qemu_cmd+=(-display none)
  else
    qemu_cmd+=(-display "default,show-cursor=on")
  fi
else
  if [[ ${headless} -eq 1 ]]; then
    qemu_cmd+=(-nographic -serial mon:stdio)
  else
    qemu_cmd+=(-display "default,show-cursor=on")
  fi
fi

log "info" "starting VM '${vm_name}' with ${cpu_count} vCPUs and ${memory_mb} MB memory"
log "info" "SSH available via tcp://127.0.0.1:${ssh_port}"
if ports=$(read_forwarded_ports); then
  while IFS=',' read -r host guest; do
    [[ -z "${host}" || -z "${guest}" ]] && continue
    log "info" "forwarding tcp/${host} -> guest ${guest}"
  done <<< "${ports}"
fi

if [[ ${daemonize} -eq 1 ]]; then
  log "info" "daemonized; serial log at ${serial_log}"
  log "info" "monitor socket at ${monitor_socket}"
  "${qemu_cmd[@]}"
else
  exec "${qemu_cmd[@]}"
fi
