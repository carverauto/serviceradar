#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install-download-integrity.sh"

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
case "${os}-${arch}" in
  linux-amd64)
    expected_sha256="${ORAS_SHA256:-6cdc692f929100feb08aa8de584d02f7bcc30ec7d88bc2adc2054d782db57c64}"
    ;;
  linux-arm64)
    expected_sha256="${ORAS_SHA256:-7649738b48fde10542bcc8b0e9b460ba83936c75fb5be01ee6d4443764a14352}"
    ;;
  darwin-arm64)
    expected_sha256="${ORAS_SHA256:-e10c6552c02d5a7c7eaf7170d3b6f7f094b675a98a1e0edf4d4478a909447245}"
    ;;
  darwin-amd64)
    expected_sha256="${ORAS_SHA256:-82c33f7da8430ea7fa7e7bdf7721be0a0d0481e5ccb2472ea438490d5e8641a9}"
    ;;
  *)
    expected_sha256="${ORAS_SHA256:-}"
    ;;
esac
if [[ "$VERSION" != "1.3.0" && -z "${ORAS_SHA256:-}" ]]; then
  expected_sha256=""
fi

mkdir -p "${INSTALL_DIR}"
sr_require_sha256 "$expected_sha256" "oras v${VERSION} ${archive}"
curl --fail --location --retry 5 --retry-all-errors --output "${tmpdir}/${archive}" "${url}"
sr_verify_sha256 "${tmpdir}/${archive}" "$expected_sha256" "oras v${VERSION} ${archive}"
tar -xzf "${tmpdir}/${archive}" -C "${tmpdir}"
install -m 0755 "${tmpdir}/oras" "${INSTALL_DIR}/oras"
echo "Installed oras $(${INSTALL_DIR}/oras version | awk '/Version:/ {print $2; exit}') to ${INSTALL_DIR}/oras"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n' "${INSTALL_DIR}" >> "${GITHUB_PATH}"
fi
