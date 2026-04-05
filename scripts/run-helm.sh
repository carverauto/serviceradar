#!/usr/bin/env bash

set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required to run Helm in CI." >&2
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

mkdir -p "${state_dir}/cache" "${state_dir}/config" "${state_dir}/data"

exec docker run --rm -i \
  --user "$(id -u):$(id -g)" \
  -v "${PWD}:/workspace" \
  -v "${state_dir}:/helm-home" \
  -w /workspace \
  -e HOME=/helm-home \
  -e HELM_CACHE_HOME=/helm-home/cache \
  -e HELM_CONFIG_HOME=/helm-home/config \
  -e HELM_DATA_HOME=/helm-home/data \
  "${image}" \
  "$@"
