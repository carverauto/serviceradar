#!/usr/bin/env bash
set -euo pipefail

version="${TINYGO_VERSION:-0.41.1}"
install_parent="${RUNNER_TEMP:-${HOME}/.local}/tinygo"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

if [[ "${version}" != "0.41.1" ]]; then
  echo "No trusted checksum is configured for TinyGo ${version}" >&2
  exit 1
fi

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64|Linux-amd64)
    platform="linux-amd64"
    expected_sha256="e156d1d93a376eef639a4143d13be07e8c463fb6cf2d7d447698ed4474d23e91"
    ;;
  Linux-aarch64|Linux-arm64)
    platform="linux-arm64"
    expected_sha256="789733bc3b5bace0bd1835a267b3ea267804a7ef1cfe69bc522c295f5226d624"
    ;;
  Darwin-x86_64|Darwin-amd64)
    platform="darwin-amd64"
    expected_sha256="1a8e62a234d3aea20793ada2c4a628de96ed7533384f0f5dc3c3f2ffa84f9bab"
    ;;
  Darwin-arm64)
    platform="darwin-arm64"
    expected_sha256="c684d154d89a452cc9c7fc5dc5fc80cb6a42445b3e44b3c12ed048692de0f341"
    ;;
  *)
    echo "Unsupported TinyGo platform: $(uname -s)-$(uname -m)" >&2
    exit 1
    ;;
esac

archive="tinygo${version}.${platform}.tar.gz"
curl --fail --location --silent --show-error \
  "https://github.com/tinygo-org/tinygo/releases/download/v${version}/${archive}" \
  --output "${tmpdir}/${archive}"

if command -v sha256sum >/dev/null 2>&1; then
  actual_sha256="$(sha256sum "${tmpdir}/${archive}" | awk '{print $1}')"
else
  actual_sha256="$(shasum -a 256 "${tmpdir}/${archive}" | awk '{print $1}')"
fi
if [[ "${actual_sha256}" != "${expected_sha256}" ]]; then
  echo "TinyGo archive checksum mismatch" >&2
  exit 1
fi

rm -rf "${install_parent}"
mkdir -p "${install_parent}"
tar -xzf "${tmpdir}/${archive}" -C "${install_parent}" --strip-components=1

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "${install_parent}/bin" >>"${GITHUB_PATH}"
else
  echo "Add ${install_parent}/bin to PATH"
fi

"${install_parent}/bin/tinygo" version
