#!/usr/bin/env bash
set -euo pipefail

VERSION="${ORAS_VERSION:-1.3.0}"
INSTALL_DIR="${INSTALL_DIR:-${HOME}/.local/bin}"

if command -v oras >/dev/null 2>&1; then
  current="$(oras version 2>/dev/null | awk '/Version:/ {print $2; exit}')"
  if [[ "${current#v}" == "${VERSION}" ]]; then
    echo "oras ${current} already installed"
    exit 0
  fi
fi

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"
case "${arch}" in
  x86_64) arch="amd64" ;;
  aarch64|arm64) arch="arm64" ;;
  *)
    echo "error: unsupported architecture: ${arch}" >&2
    exit 1
    ;;
esac

archive="oras_${VERSION}_${os}_${arch}.tar.gz"
url="https://github.com/oras-project/oras/releases/download/v${VERSION}/${archive}"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

mkdir -p "${INSTALL_DIR}"
curl --fail --location --retry 5 --retry-all-errors --output "${tmpdir}/${archive}" "${url}"
tar -xzf "${tmpdir}/${archive}" -C "${tmpdir}"
install -m 0755 "${tmpdir}/oras" "${INSTALL_DIR}/oras"
echo "Installed oras $(${INSTALL_DIR}/oras version | awk '/Version:/ {print $2; exit}') to ${INSTALL_DIR}/oras"
