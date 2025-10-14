#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

mkdir -p "${HOME}/.docker"
config_path="${HOME}/.docker/config.json"
registry="${GHCR_REGISTRY:-ghcr.io}"

if [[ -f "${config_path}" && -z "${DOCKER_AUTH_CONFIG_JSON:-}" && -z "${GHCR_DOCKER_AUTH:-}" && -z "${GHCR_USERNAME:-}" && -z "${GHCR_TOKEN:-}" ]]; then
  echo "Docker config already present at ${config_path}; nothing to do." >&2
  exit 0
fi

if [[ -n "${DOCKER_AUTH_CONFIG_JSON:-}" ]]; then
  printf '%s\n' "${DOCKER_AUTH_CONFIG_JSON}" > "${config_path}"
  exit 0
fi

if [[ -n "${GHCR_DOCKER_AUTH:-}" ]]; then
  auth_entry="${GHCR_DOCKER_AUTH}"
elif [[ -n "${GHCR_USERNAME:-}" && -n "${GHCR_TOKEN:-}" ]]; then
  auth_entry=$(printf '%s:%s' "${GHCR_USERNAME}" "${GHCR_TOKEN}" | base64 | tr -d '\n')
else
  cat >&2 <<EOF_ERR
Missing registry credentials.
Provide one of the following before running this script:
  * DOCKER_AUTH_CONFIG_JSON: Full docker config JSON.
  * GHCR_DOCKER_AUTH: Base64-encoded "username:token" string for ${registry}.
  * GHCR_USERNAME and GHCR_TOKEN environment variables.
EOF_ERR
  exit 1
fi

cat > "${config_path}" <<EOF_JSON
{
  "auths": {
    "${registry}": {
      "auth": "${auth_entry}"
    }
  }
}
EOF_JSON
