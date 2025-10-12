#!/usr/bin/env bash
# AlmaLinux image acquisition for the sysmon-vm checker environment.
#
# Reads dist/sysmonvm/config.yaml (or the workspace override) to discover the
# AlmaLinux cloud image URL, expected checksum, and destination filename.
#
# Usage:
#   scripts/sysmonvm/fetch-image.sh [--workspace <path>] [--force]
#
# Options:
#   --workspace <path>  Override the sysmon-vm workspace directory.
#   --force             Re-download the image even if it already exists.
#   --help              Display this message.
#
# Environment:
#   SR_SYSMONVM_WORKSPACE  Alternate default workspace location.

set -euo pipefail

log() {
  printf '[sysmonvm][fetch][%s] %s\n' "$1" "${2-}"
}

die() {
  log "error" "${1-unknown error}"
  exit "${2-1}"
}

print_usage() {
  sed -n '1,40p' "${BASH_SOURCE[0]}"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
default_workspace="${repo_root}/dist/sysmonvm"
workspace="${SR_SYSMONVM_WORKSPACE:-$default_workspace}"
force_download=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      shift
      [[ $# -gt 0 ]] || die "missing value for --workspace"
      workspace="$1"
      ;;
    --force)
      force_download=1
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

read_image_field() {
  local key="$1"
  local target="${key}:"
  awk -v target="${target}" '
    /^image:/ {in_image=1; next}
    /^[^[:space:]]/ {if (in_image) exit 0; in_image=0}
    in_image && $1 == target {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      print $0
      exit 0
    }
  ' "${config_path}"
}

image_url="$(read_image_field "url")"
image_checksum="$(read_image_field "checksum")"
image_filename="$(read_image_field "local_filename")"

[[ -n "${image_url}" ]] || die "image.url missing from ${config_path}"
[[ -n "${image_filename}" ]] || die "image.local_filename missing from ${config_path}"

images_dir="${workspace}/images"
mkdir -p "${images_dir}"

destination="${images_dir}/${image_filename}"

if [[ -f "${destination}" && "${force_download}" -eq 0 ]]; then
  log "info" "image already present at ${destination}; use --force to re-download"
else
  tmp_path="${destination}.part"
  log "info" "downloading AlmaLinux image from ${image_url}"
  rm -f "${tmp_path}"
  wget --show-progress -O "${tmp_path}" "${image_url}" || {
    rm -f "${tmp_path}"
    die "failed to download image"
  }
  mv "${tmp_path}" "${destination}"
  log "info" "download complete: ${destination}"
fi

# Checksum validation
if [[ -n "${image_checksum}" && "${image_checksum}" != "sha256:REPLACE_ME" ]]; then
  expected="${image_checksum#sha256:}"
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "${destination}" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "${destination}" | awk '{print $1}')"
  else
    die "neither sha256sum nor shasum available for checksum verification"
  fi

  if [[ "${actual}" != "${expected}" ]]; then
    rm -f "${destination}"
    die "checksum mismatch for ${destination} (expected ${expected}, got ${actual})"
  fi
  log "info" "checksum verification succeeded"
else
  log "warn" "checksum is unset; compute with 'shasum -a 256 ${destination}' and update config.yaml"
fi

log "info" "image fetch step complete"
