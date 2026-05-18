#!/usr/bin/env bash

set -euo pipefail

version="${GITLEAKS_VERSION:-v8.30.0}"
version_no_v="${version#v}"
install_root="${RUNNER_TEMP:-${HOME}/.local}/bin"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install-download-integrity.sh"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64|Linux-amd64)
    asset="gitleaks_${version_no_v}_linux_x64.tar.gz"
    expected_sha256="${GITLEAKS_SHA256:-79a3ab579b53f71efd634f3aaf7e04a0fa0cf206b7ed434638d1547a2470a66e}"
    ;;
  Linux-aarch64|Linux-arm64)
    asset="gitleaks_${version_no_v}_linux_arm64.tar.gz"
    expected_sha256="${GITLEAKS_SHA256:-b4cbbb6ddf7d1b2a603088cd03a4e3f7ce48ee7fd449b51f7de6ee2906f5fa2f}"
    ;;
  Darwin-arm64)
    asset="gitleaks_${version_no_v}_darwin_arm64.tar.gz"
    expected_sha256="${GITLEAKS_SHA256:-b251ab2bcd4cd8ba9e56ff37698c033ebf38582b477d21ebd86586d927cf87e7}"
    ;;
  Darwin-x86_64)
    asset="gitleaks_${version_no_v}_darwin_x64.tar.gz"
    expected_sha256="${GITLEAKS_SHA256:-ca221d012d247080c2f6f61f4b7a83bffa2453806b0c195c795bbe9a8c775ed5}"
    ;;
  *)
    echo "Unsupported platform: $(uname -s)-$(uname -m)" >&2
    exit 1
    ;;
esac

if [[ "$version" != "v8.30.0" && -z "${GITLEAKS_SHA256:-}" ]]; then
  expected_sha256=""
fi

sr_download_verified \
  "https://github.com/gitleaks/gitleaks/releases/download/${version}/${asset}" \
  "${tmpdir}/gitleaks.tgz" \
  "$expected_sha256" \
  "gitleaks ${version} ${asset}"
tar -xzf "${tmpdir}/gitleaks.tgz" -C "${tmpdir}"

mkdir -p "${install_root}"
install -m 0755 "${tmpdir}/gitleaks" "${install_root}/gitleaks"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "${install_root}" >> "${GITHUB_PATH}"
else
  export PATH="${install_root}:${PATH}"
fi

"${install_root}/gitleaks" version
