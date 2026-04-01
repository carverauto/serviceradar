#!/usr/bin/env bash

set -euo pipefail

version="${SYFT_VERSION:-v1.42.3}"
version_no_v="${version#v}"
install_root="${RUNNER_TEMP:-${HOME}/.local}/bin"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64|Linux-amd64)
    asset="syft_${version_no_v}_linux_amd64.tar.gz"
    ;;
  Linux-aarch64|Linux-arm64)
    asset="syft_${version_no_v}_linux_arm64.tar.gz"
    ;;
  Darwin-arm64)
    asset="syft_${version_no_v}_darwin_arm64.tar.gz"
    ;;
  Darwin-x86_64)
    asset="syft_${version_no_v}_darwin_amd64.tar.gz"
    ;;
  *)
    echo "Unsupported platform: $(uname -s)-$(uname -m)" >&2
    exit 1
    ;;
esac

curl -fsSL \
  "https://github.com/anchore/syft/releases/download/${version}/${asset}" \
  -o "${tmpdir}/syft.tgz"
tar -xzf "${tmpdir}/syft.tgz" -C "${tmpdir}"

mkdir -p "${install_root}"
install -m 0755 "${tmpdir}/syft" "${install_root}/syft"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "${install_root}" >> "${GITHUB_PATH}"
else
  export PATH="${install_root}:${PATH}"
fi

"${install_root}/syft" version
