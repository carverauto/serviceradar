#!/usr/bin/env bash

set -euo pipefail

version="${OSV_SCANNER_VERSION:-v2.3.5}"
install_root="${RUNNER_TEMP:-${HOME}/.local}/bin"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64|Linux-amd64)
    asset="osv-scanner_linux_amd64"
    ;;
  Linux-aarch64|Linux-arm64)
    asset="osv-scanner_linux_arm64"
    ;;
  Darwin-arm64)
    asset="osv-scanner_darwin_arm64"
    ;;
  Darwin-x86_64)
    asset="osv-scanner_darwin_amd64"
    ;;
  *)
    echo "Unsupported platform: $(uname -s)-$(uname -m)" >&2
    exit 1
    ;;
esac

mkdir -p "${install_root}"
curl -fsSL \
  "https://github.com/google/osv-scanner/releases/download/${version}/${asset}" \
  -o "${install_root}/osv-scanner"
chmod +x "${install_root}/osv-scanner"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "${install_root}" >> "${GITHUB_PATH}"
else
  export PATH="${install_root}:${PATH}"
fi

"${install_root}/osv-scanner" --version
