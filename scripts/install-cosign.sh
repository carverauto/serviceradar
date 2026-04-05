#!/usr/bin/env bash

set -euo pipefail

version="${COSIGN_VERSION:-v3.0.3}"
install_root="${RUNNER_TEMP:-${HOME}/.local}/bin"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

case "$(uname -m)" in
  x86_64|amd64)
    asset="cosign-linux-amd64"
    ;;
  aarch64|arm64)
    asset="cosign-linux-arm64"
    ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

mkdir -p "${install_root}"
curl -fsSL \
  "https://github.com/sigstore/cosign/releases/download/${version}/${asset}" \
  -o "${tmpdir}/cosign"
install -m 0755 "${tmpdir}/cosign" "${install_root}/cosign"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "${install_root}" >> "${GITHUB_PATH}"
else
  export PATH="${install_root}:${PATH}"
fi

"${install_root}/cosign" version
