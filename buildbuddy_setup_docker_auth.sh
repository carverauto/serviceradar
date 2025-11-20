#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

mkdir -p "${HOME}/.docker"
config_path="${HOME}/.docker/config.json"
registry="${GHCR_REGISTRY:-ghcr.io}"
dockerhub_registry="https://index.docker.io/v1/"

if [[ -f "${config_path}" && -z "${DOCKER_AUTH_CONFIG_JSON:-}" && -z "${GHCR_DOCKER_AUTH:-}" && -z "${GHCR_USERNAME:-}" && -z "${GHCR_TOKEN:-}" ]]; then
  echo "Docker config already present at ${config_path}; nothing to do." >&2
  exit 0
fi

if [[ -n "${DOCKER_AUTH_CONFIG_JSON:-}" ]]; then
  printf '%s\n' "${DOCKER_AUTH_CONFIG_JSON}" > "${config_path}"
  exit 0
fi

declare -A auths

if [[ -n "${GHCR_DOCKER_AUTH:-}" ]]; then
  auths["${registry}"]="${GHCR_DOCKER_AUTH}"
elif [[ -n "${GHCR_USERNAME:-}" && -n "${GHCR_TOKEN:-}" ]]; then
  auths["${registry}"]=$(printf '%s:%s' "${GHCR_USERNAME}" "${GHCR_TOKEN}" | base64 | tr -d '\n')
fi

if [[ -n "${DOCKERHUB_USERNAME:-}" && -n "${DOCKERHUB_TOKEN:-}" ]]; then
  auths["${dockerhub_registry}"]=$(printf '%s:%s' "${DOCKERHUB_USERNAME}" "${DOCKERHUB_TOKEN}" | base64 | tr -d '\n')
fi

if (( ${#auths[@]} == 0 )); then
  cat >&2 <<EOF_ERR
Missing registry credentials.
Provide one of the following before running this script:
  * DOCKER_AUTH_CONFIG_JSON: Full docker config JSON.
  * GHCR_DOCKER_AUTH: Base64-encoded "username:token" string for ${registry}.
  * GHCR_USERNAME and GHCR_TOKEN environment variables.
Optional (helps avoid Docker Hub rate limits):
  * DOCKERHUB_USERNAME and DOCKERHUB_TOKEN environment variables.
EOF_ERR
  exit 1
fi

{
  printf '{ "auths": {'
  first=1
  for reg in "${!auths[@]}"; do
    auth="${auths[$reg]}"
    if (( first == 0 )); then
      printf ','
    fi
    first=0
    printf '"%s": {"auth":"%s"}' "${reg}" "${auth}"
  done
  printf '} }\n'
} > "${config_path}"
