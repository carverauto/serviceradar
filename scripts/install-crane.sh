#!/usr/bin/env bash
# Install the pinned, checksum-verified crane binary for CI runners. crane is a
# static Go binary that talks to registries directly, so it works on ARC runners
# that have no dockerd and no container socket. This file is the single crane
# pin; install-skopeo.sh delegates here.

set -euo pipefail

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
  echo "error: install-download-integrity.sh not found next to install-crane.sh" >&2
  exit 1
fi
# shellcheck source=scripts/install-download-integrity.sh
source "${integrity_helper}"

install_root="${RUNNER_TEMP:-${HOME}/.local}/bin"
crane_version="${CRANE_VERSION:-v0.21.9}"

case "$(uname -m)" in
  x86_64|amd64)
    crane_archive="go-containerregistry_Linux_x86_64.tar.gz"
    crane_sha256="${CRANE_SHA256:-5c16d8ddb971cb1d5e6ed8b1e743da8224414eeba2c2762d8f1a61b2f095699e}"
    ;;
  aarch64|arm64)
    crane_archive="go-containerregistry_Linux_arm64.tar.gz"
    crane_sha256="${CRANE_SHA256:-1f4c647b7bb260ab5435661df5b526cf59950ebf95201790db7183ac189cbcbd}"
    ;;
  *)
    echo "Unsupported architecture for crane: $(uname -m)" >&2
    exit 1
    ;;
esac

mkdir -p "${install_root}"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
sr_download_verified \
  "https://github.com/google/go-containerregistry/releases/download/${crane_version}/${crane_archive}" \
  "${tmpdir}/${crane_archive}" \
  "${crane_sha256}" \
  "crane ${crane_version} ${crane_archive}"
tar -xzf "${tmpdir}/${crane_archive}" -C "${tmpdir}" crane
install -m 0755 "${tmpdir}/crane" "${install_root}/crane"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n' "${install_root}" >> "${GITHUB_PATH}"
fi

"${install_root}/crane" version
