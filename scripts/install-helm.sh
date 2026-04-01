#!/usr/bin/env bash

set -euo pipefail

version="${HELM_VERSION:-v3.14.4}"
install_root="${RUNNER_TEMP:-${HOME}/.local}/bin"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

case "$(uname -m)" in
  x86_64|amd64)
    arch="amd64"
    ;;
  aarch64|arm64)
    arch="arm64"
    ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

archive="helm-${version}-linux-${arch}.tar.gz"
curl -fsSL "https://get.helm.sh/${archive}" -o "${tmpdir}/${archive}"
tar -xzf "${tmpdir}/${archive}" -C "${tmpdir}"

mkdir -p "${install_root}"
install -m 0755 "${tmpdir}/linux-${arch}/helm" "${install_root}/helm"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "${install_root}" >> "${GITHUB_PATH}"
else
  export PATH="${install_root}:${PATH}"
fi

"${install_root}/helm" version --short
