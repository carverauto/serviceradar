#!/usr/bin/env bash
# Run helm without a container runtime. The Forgejo-era wrapper exec'd
# alpine/helm via docker --volumes-from $HOSTNAME. ARC signing runners
# have no dockerd and no /var/run/docker.sock.

set -euo pipefail

version="${HELM_VERSION:-3.14.4}"
version="${version#v}"
install_root="${RUNNER_TEMP:-${HOME}/.local}/bin"
workspace_dir="${PWD}"
state_dir="${HELM_STATE_DIR:-${workspace_dir}/.helm-home}"
mkdir -p "${state_dir}/cache" "${state_dir}/config" "${state_dir}/data" "${install_root}"

if [[ "${HELM_USE_DOCKER:-}" == "1" ]]; then
  echo "HELM_USE_DOCKER=1 is no longer supported; install helm or use this wrapper's native binary." >&2
  exit 1
fi

helm_os="$(uname -s | tr '[:upper:]' '[:lower:]')"
helm_arch="$(uname -m)"
case "${helm_arch}" in
  x86_64|amd64) helm_arch="amd64" ;;
  aarch64|arm64) helm_arch="arm64" ;;
  *)
    echo "error: unsupported helm architecture: ${helm_arch}" >&2
    exit 1
    ;;
esac

case "${helm_os}-${helm_arch}" in
  linux-amd64)
    helm_sha256="${HELM_SHA256:-a5844ef2c38ef6ddf3b5a8f7d91e7e0e8ebc39a38bb3fc8013d629c1ef29c259}"
    ;;
  linux-arm64)
    helm_sha256="${HELM_SHA256:-113ccc53b7c57c2aba0cd0aa560b5500841b18b5210d78641acfddc53dac8ab2}"
    ;;
  darwin-arm64)
    helm_sha256="${HELM_SHA256:-61e9c5455f06b2ad0a1280975bf65892e707adc19d766b0cf4e9006e3b7b4b6c}"
    ;;
  darwin-amd64)
    helm_sha256="${HELM_SHA256:-73434aeac36ad068ce2e5582b8851a286dc628eae16494a26e2ad0b24a7199f9}"
    ;;
  *)
    echo "error: no pinned helm checksum for ${helm_os}-${helm_arch}" >&2
    exit 1
    ;;
esac

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file}" | awk '{print $1}'
    return
  fi
  shasum -a 256 "${file}" | awk '{print $1}'
}

resolve_helm() {
  if [[ -n "${SERVICERADAR_HELM_BIN:-}" && -x "${SERVICERADAR_HELM_BIN}" ]]; then
    printf '%s\n' "${SERVICERADAR_HELM_BIN}"
    return 0
  fi
  if command -v helm >/dev/null 2>&1; then
    command -v helm
    return 0
  fi
  if [[ -x "${install_root}/helm" ]]; then
    printf '%s\n' "${install_root}/helm"
    return 0
  fi
  return 1
}

install_helm() {
  local archive="helm-v${version}-${helm_os}-${helm_arch}.tar.gz"
  local tmpdir archive_path actual
  tmpdir="$(mktemp -d)"
  archive_path="${tmpdir}/${archive}"
  curl -fsSL "https://get.helm.sh/${archive}" -o "${archive_path}"
  actual="$(sha256_file "${archive_path}")"
  if [[ "${actual}" != "${helm_sha256}" ]]; then
    echo "error: SHA256 mismatch for helm v${version} ${archive}" >&2
    echo "expected: ${helm_sha256}" >&2
    echo "actual:   ${actual}" >&2
    rm -rf "${tmpdir}"
    exit 1
  fi
  tar -xzf "${archive_path}" -C "${tmpdir}" "${helm_os}-${helm_arch}/helm"
  install -m 0755 "${tmpdir}/${helm_os}-${helm_arch}/helm" "${install_root}/helm"
  rm -rf "${tmpdir}"
  if [[ -n "${GITHUB_PATH:-}" ]]; then
    echo "${install_root}" >> "${GITHUB_PATH}"
  fi
  printf '%s\n' "${install_root}/helm"
}

helm_bin="$(resolve_helm || true)"
if [[ -z "${helm_bin}" ]]; then
  helm_bin="$(install_helm)"
fi

export HOME="${state_dir}"
export HELM_CACHE_HOME="${state_dir}/cache"
export HELM_CONFIG_HOME="${state_dir}/config"
export HELM_DATA_HOME="${state_dir}/data"

exec "${helm_bin}" "$@"
