#!/usr/bin/env bash

set -euo pipefail

version="${SYFT_VERSION:-v1.42.3}"
version_no_v="${version#v}"
install_root="${RUNNER_TEMP:-${HOME}/.local}/bin"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install-download-integrity.sh"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64|Linux-amd64)
    asset="syft_${version_no_v}_linux_amd64.tar.gz"
    expected_sha256="${SYFT_SHA256:-0d6be741479eddd2c8644a288990c04f3df0d609bbc1599a005532a9dff63509}"
    ;;
  Linux-aarch64|Linux-arm64)
    asset="syft_${version_no_v}_linux_arm64.tar.gz"
    expected_sha256="${SYFT_SHA256:-dc630590c953347789d08f8ebf57c7d8094db89100785fcd94b1cddeac791804}"
    ;;
  Darwin-arm64)
    asset="syft_${version_no_v}_darwin_arm64.tar.gz"
    expected_sha256="${SYFT_SHA256:-d71ee7db2be0fe2e96f679fd9d69ef04274cc86c8604707797080a21070b3f32}"
    ;;
  Darwin-x86_64)
    asset="syft_${version_no_v}_darwin_amd64.tar.gz"
    expected_sha256="${SYFT_SHA256:-c00d01b7c43504708c8922d643d1cbaefa62ca8876baa4d2c2cf4c3be43707a9}"
    ;;
  *)
    echo "Unsupported platform: $(uname -s)-$(uname -m)" >&2
    exit 1
    ;;
esac

if [[ "$version" != "v1.42.3" && -z "${SYFT_SHA256:-}" ]]; then
  expected_sha256=""
fi

sr_download_verified \
  "https://github.com/anchore/syft/releases/download/${version}/${asset}" \
  "${tmpdir}/syft.tgz" \
  "$expected_sha256" \
  "syft ${version} ${asset}"
tar -xzf "${tmpdir}/syft.tgz" -C "${tmpdir}"

mkdir -p "${install_root}"
install -m 0755 "${tmpdir}/syft" "${install_root}/syft"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "${install_root}" >> "${GITHUB_PATH}"
else
  export PATH="${install_root}:${PATH}"
fi

"${install_root}/syft" version
