#!/usr/bin/env bash

set -euo pipefail

version="${COSIGN_VERSION:-v3.0.3}"
install_root="${RUNNER_TEMP:-${HOME}/.local}/bin"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install-download-integrity.sh"

case "$(uname -m)" in
  x86_64|amd64)
    asset="cosign-linux-amd64"
    expected_sha256="${COSIGN_SHA256:-052363a0e23e2e7ed53641351b8b420918e7e08f9c1d8a42a3dd3877a78a2e10}"
    ;;
  aarch64|arm64)
    asset="cosign-linux-arm64"
    expected_sha256="${COSIGN_SHA256:-81398231362031e3c7afd6a7508c57049460cd7e02736f1ebe89a452102253e5}"
    ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

if [[ "$version" != "v3.0.3" && -z "${COSIGN_SHA256:-}" ]]; then
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
