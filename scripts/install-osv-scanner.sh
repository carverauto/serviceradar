#!/usr/bin/env bash

set -euo pipefail

version="${OSV_SCANNER_VERSION:-v2.3.5}"
install_root="${RUNNER_TEMP:-${HOME}/.local}/bin"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install-download-integrity.sh"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64|Linux-amd64)
    asset="osv-scanner_linux_amd64"
    expected_sha256="${OSV_SCANNER_SHA256:-bb30c580afe5e757d3e959f4afd08a4795ea505ef84c46962b9a738aa573b41b}"
    ;;
  Linux-aarch64|Linux-arm64)
    asset="osv-scanner_linux_arm64"
    expected_sha256="${OSV_SCANNER_SHA256:-fa46ad2b3954db5d5335303d45de921613393285d9a93c140b63b40e35e9ce50}"
    ;;
  Darwin-arm64)
    asset="osv-scanner_darwin_arm64"
    expected_sha256="${OSV_SCANNER_SHA256:-b740efe0b08fb817865e818a498997d5f042f14b8eeafb6393176ce84dd09cf6}"
    ;;
  Darwin-x86_64)
    asset="osv-scanner_darwin_amd64"
    expected_sha256="${OSV_SCANNER_SHA256:-3b1c72d59dcbad99fa4eb2c72bf2e82017f83e0268340e4b00af76a1fea32c85}"
    ;;
  *)
    echo "Unsupported platform: $(uname -s)-$(uname -m)" >&2
    exit 1
    ;;
esac

if [[ "$version" != "v2.3.5" && -z "${OSV_SCANNER_SHA256:-}" ]]; then
  expected_sha256=""
fi

mkdir -p "${install_root}"
sr_download_verified \
  "https://github.com/google/osv-scanner/releases/download/${version}/${asset}" \
  "${tmpdir}/osv-scanner" \
  "$expected_sha256" \
  "osv-scanner ${version} ${asset}"
install -m 0755 "${tmpdir}/osv-scanner" "${install_root}/osv-scanner"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "${install_root}" >> "${GITHUB_PATH}"
else
  export PATH="${install_root}:${PATH}"
fi

"${install_root}/osv-scanner" --version
