#!/usr/bin/env bash
# Install skopeo for non-root CI runners (GitHub ARC). The old Forgejo image
# baked it in; ensure-forgejo-tools.sh cannot apt-get without root.
#
# Extract via crane. ARC signing runners can write docker login config, but
# they have no dockerd and no container socket.

set -euo pipefail

if command -v skopeo >/dev/null 2>&1; then
  echo "skopeo already on PATH: $(command -v skopeo)"
  exit 0
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
integrity_helper=""
for candidate in \
  "${script_dir}/install-download-integrity.sh" \
  "${GITHUB_WORKSPACE:-}/scripts/install-download-integrity.sh" \
  "${script_dir}/../scripts/install-download-integrity.sh"; do
  if [[ -f "${candidate}" ]]; then
    integrity_helper="${candidate}"
    break
  fi
done
if [[ -z "${integrity_helper}" ]]; then
  echo "error: install-download-integrity.sh not found next to install-skopeo.sh" >&2
  exit 1
fi
# shellcheck source=scripts/install-download-integrity.sh
source "${integrity_helper}"

install_root="${RUNNER_TEMP:-${HOME}/.local}/bin"
mkdir -p "${install_root}"
dest="${install_root}/skopeo"
image="${SKOPEO_IMAGE:-quay.io/skopeo/stable:v1.17.0}"
crane_version="${CRANE_VERSION:-v0.21.9}"

case "$(uname -m)" in
  x86_64|amd64)
    crane_archive="go-containerregistry_Linux_x86_64.tar.gz"
    crane_sha256="${CRANE_SHA256:-5c16d8ddb971cb1d5e6ed8b1e743da8224414eeba2c2762d8f1a61b2f095699e}"
    skopeo_platform="linux/amd64"
    ;;
  aarch64|arm64)
    crane_archive="go-containerregistry_Linux_arm64.tar.gz"
    crane_sha256="${CRANE_SHA256:-1f4c647b7bb260ab5435661df5b526cf59950ebf95201790db7183ac189cbcbd}"
    skopeo_platform="linux/arm64"
    ;;
  *)
    echo "Unsupported architecture for skopeo bootstrap: $(uname -m)" >&2
    exit 1
    ;;
esac

resolve_crane() {
  if command -v crane >/dev/null 2>&1; then
    command -v crane
    return 0
  fi
  local crane_bin="${install_root}/crane"
  if [[ -x "${crane_bin}" ]]; then
    printf '%s\n' "${crane_bin}"
    return 0
  fi
  return 1
}

install_crane() {
  local tmpdir archive_path
  tmpdir="$(mktemp -d)"
  archive_path="${tmpdir}/${crane_archive}"
  sr_download_verified \
    "https://github.com/google/go-containerregistry/releases/download/${crane_version}/${crane_archive}" \
    "${archive_path}" \
    "${crane_sha256}" \
    "crane ${crane_version} ${crane_archive}"
  tar -xzf "${archive_path}" -C "${tmpdir}" crane
  install -m 0755 "${tmpdir}/crane" "${install_root}/crane"
  rm -rf "${tmpdir}"
  printf '%s\n' "${install_root}/crane"
}

crane_bin="$(resolve_crane || true)"
if [[ -z "${crane_bin}" ]]; then
  crane_bin="$(install_crane)"
fi

export_dir="$(mktemp -d)"
trap 'rm -rf "${export_dir}"' EXIT
if ! "${crane_bin}" export --platform "${skopeo_platform}" "${image}" - | tar -C "${export_dir}" -xf -; then
  echo "error: failed to export ${image} with crane" >&2
  exit 1
fi

extracted=""
for candidate in \
  "${export_dir}/usr/bin/skopeo" \
  "${export_dir}/bin/skopeo"; do
  if [[ -f "${candidate}" ]]; then
    extracted="${candidate}"
    break
  fi
done
if [[ -z "${extracted}" ]]; then
  echo "error: ${image} did not contain usr/bin/skopeo or bin/skopeo" >&2
  exit 1
fi

install -m 0755 "${extracted}" "${dest}"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "${install_root}" >> "${GITHUB_PATH}"
fi
export PATH="${install_root}:${PATH}"

"${dest}" --version
