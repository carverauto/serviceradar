#!/usr/bin/env bash

set -euo pipefail

version="${COSIGN_VERSION:-v3.1.4}"
install_root="${RUNNER_TEMP:-${HOME}/.local}/bin"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install-download-integrity.sh"

case "$(uname -m)" in
  x86_64|amd64)
    asset="cosign-linux-amd64"
    expected_sha256="${COSIGN_SHA256:-424e2c97d0b45fd7a6b608a87f090f35633f4c23ece5f092d48bba11aaf4bbfa}"
    ;;
  aarch64|arm64)
    asset="cosign-linux-arm64"
    expected_sha256="${COSIGN_SHA256:-ade83b7aac62e131cacfe96d958948b2150cc9efec46a570a2649b8e27dedad2}"
    ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

if [[ "$version" != "v3.1.4" && -z "${COSIGN_SHA256:-}" ]]; then
  expected_sha256=""
fi

mkdir -p "${install_root}"
sr_download_verified \
  "https://github.com/sigstore/cosign/releases/download/${version}/${asset}" \
  "${tmpdir}/cosign" \
  "$expected_sha256" \
  "cosign ${version} ${asset}"
install -m 0755 "${tmpdir}/cosign" "${install_root}/cosign"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "${install_root}" >> "${GITHUB_PATH}"
else
  export PATH="${install_root}:${PATH}"
fi

"${install_root}/cosign" version
