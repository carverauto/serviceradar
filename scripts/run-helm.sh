#!/usr/bin/env bash

set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required to provision Helm in CI." >&2
  exit 1
fi

version="${HELM_VERSION:-3.14.4}"
image="${HELM_CONTAINER_IMAGE:-alpine/helm:${version#v}}"
state_dir="${HELM_STATE_DIR:-}"
cleanup_state=0

if [[ -z "${state_dir}" ]]; then
  state_dir="$(mktemp -d)"
  cleanup_state=1
fi

if [[ "${cleanup_state}" -eq 1 ]]; then
  trap 'rm -rf "${state_dir}"' EXIT
fi

mkdir -p "${state_dir}/bin" "${state_dir}/cache" "${state_dir}/config" "${state_dir}/data"

helm_bin="${state_dir}/bin/helm"
if [[ ! -x "${helm_bin}" ]]; then
  if ! docker run --rm --entrypoint cat "${image}" /usr/bin/helm >"${helm_bin}" 2>/dev/null \
    && ! docker run --rm --entrypoint cat "${image}" /usr/local/bin/helm >"${helm_bin}" 2>/dev/null \
    && ! docker run --rm --entrypoint cat "${image}" /bin/helm >"${helm_bin}" 2>/dev/null; then
    echo "failed to extract helm binary from ${image}" >&2
    exit 1
  fi

  chmod +x "${helm_bin}"
fi

export HOME="${state_dir}"
export HELM_CACHE_HOME="${state_dir}/cache"
export HELM_CONFIG_HOME="${state_dir}/config"
export HELM_DATA_HOME="${state_dir}/data"

exec "${helm_bin}" "$@"
