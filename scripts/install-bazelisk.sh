#!/usr/bin/env bash

set -euo pipefail

version="${BAZELISK_VERSION:-v1.28.1}"
install_root="${RUNNER_TEMP:-${HOME}/.local}/bin"

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
curl -fsSL \
  "https://github.com/bazelbuild/bazelisk/releases/download/${version}/${asset}" \
  -o "${install_root}/bazelisk"
chmod +x "${install_root}/bazelisk"
ln -sf bazelisk "${install_root}/bazel"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "${install_root}" >> "${GITHUB_PATH}"
else
  export PATH="${install_root}:${PATH}"
fi

"${install_root}/bazelisk" --version
