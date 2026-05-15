#!/usr/bin/env bash

set -euo pipefail

version="${BAZELISK_VERSION:-v1.28.1}"
install_root="${RUNNER_TEMP:-${HOME}/.local}/bin"
base_url="${BAZELISK_BASE_URL:-https://github.com/bazelbuild/bazelisk/releases/download}"
retries="${BAZELISK_DOWNLOAD_RETRIES:-5}"

case "$(uname -m)" in
  x86_64|amd64)
    asset="bazelisk-linux-amd64"
    ;;
  aarch64|arm64)
    asset="bazelisk-linux-arm64"
    ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

mkdir -p "${install_root}"
install_path="${install_root}/bazelisk"
if command -v bazelisk >/dev/null 2>&1; then
  existing_bazelisk="$(command -v bazelisk)"
  if [[ "${existing_bazelisk}" != "${install_path}" ]]; then
    cp "${existing_bazelisk}" "${install_path}"
  fi
else
  tmp_download="${install_root}/bazelisk.$$"
  rm -f "${tmp_download}"
  curl_args=(
    --fail
    --show-error
    --location
    --connect-timeout 20
    --retry "${retries}"
    --retry-delay 2
    --retry-max-time 300
  )
  if curl --help all 2>/dev/null | grep -q -- "--retry-all-errors"; then
    curl_args+=(--retry-all-errors)
  fi

  curl "${curl_args[@]}" \
    "${base_url}/${version}/${asset}" \
    -o "${tmp_download}"
  mv "${tmp_download}" "${install_path}"
fi
chmod +x "${install_path}"
ln -sf bazelisk "${install_root}/bazel"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "${install_root}" >> "${GITHUB_PATH}"
else
  export PATH="${install_root}:${PATH}"
fi

"${install_root}/bazelisk" --version
