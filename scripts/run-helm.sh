#!/usr/bin/env bash

set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required to run Helm in CI." >&2
  exit 1
fi

version="${HELM_VERSION:-3.14.4}"
image="${HELM_CONTAINER_IMAGE:-alpine/helm:${version#v}}"
workspace_dir="${PWD}"
state_dir="${HELM_STATE_DIR:-${workspace_dir}/.helm-home}"
cleanup_state=0
container_id="${HOSTNAME:-}"

if [[ -z "${state_dir}" ]]; then
  state_dir="$(mktemp -d)"
  cleanup_state=1
fi

if [[ "${cleanup_state}" -eq 1 ]]; then
  trap 'rm -rf "${state_dir}"' EXIT
fi

mkdir -p "${state_dir}/cache" "${state_dir}/config" "${state_dir}/data"

if [[ -z "${container_id}" ]]; then
  echo "HOSTNAME is required to inherit the Forgejo job container volumes." >&2
  exit 1
fi

docker_host="${DOCKER_HOST:-}"
if [[ "${docker_host}" == unix://* ]]; then
  docker_socket="${docker_host#unix://}"
  if [[ ! -S "${docker_socket}" && -S /var/run/docker.sock ]]; then
    export DOCKER_HOST="unix:///var/run/docker.sock"
  fi
fi

exec docker run --rm -i \
  --volumes-from "${container_id}" \
  --user "$(id -u):$(id -g)" \
  -w "${workspace_dir}" \
  -e HOME="${state_dir}" \
  -e HELM_CACHE_HOME="${state_dir}/cache" \
  -e HELM_CONFIG_HOME="${state_dir}/config" \
  -e HELM_DATA_HOME="${state_dir}/data" \
  "${image}" \
  "$@"
