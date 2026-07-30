#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

mkdir -p "${HOME}/.docker"
config_path="${HOME}/.docker/config.json"
# Two DISTINCT registries, deliberately not collapsed into one variable.
#
# The primary registry is where this repo pushes its own images -- Harbor in CI, via
# OCI_REGISTRY. ghcr.io is where it PULLS third-party base images from, notably
# ghcr.io/cloudnative-pg/postgresql, which //integration_tests/srql takes as test data.
#
# These used to share a single `registry` variable, `${OCI_REGISTRY:-${GHCR_REGISTRY:-ghcr.io}}`,
# with an if/elif chain writing whichever credentials existed under that one key. With
# OCI_REGISTRY set to Harbor that had two consequences:
#
#   * ghcr.io got no entry at all, so every CNPG pull was anonymous and subject to ghcr's
#     anonymous rate limit -- an intermittent 403 during the Bazel loading phase, which
#     surfaces as "no such package" on targets that have nothing to do with containers.
#   * GHCR_USERNAME/GHCR_TOKEN, if ever set, would have been written under the *Harbor* key,
#     sending a GitHub token to Harbor. Nothing had set them yet; it was waiting.
oci_registry="${OCI_REGISTRY:-ghcr.io}"
ghcr_registry="${GHCR_REGISTRY:-ghcr.io}"
dockerhub_registry="https://index.docker.io/v1/"

if [[ -f "${config_path}" && -z "${DOCKER_AUTH_CONFIG_JSON:-}" && -z "${OCI_DOCKER_AUTH:-}" && -z "${OCI_USERNAME:-}" && -z "${OCI_TOKEN:-}" && -z "${GHCR_DOCKER_AUTH:-}" && -z "${GHCR_USERNAME:-}" && -z "${GHCR_TOKEN:-}" ]]; then
  echo "Docker config already present at ${config_path}; nothing to do." >&2
  exit 0
fi

if [[ -n "${DOCKER_AUTH_CONFIG_JSON:-}" ]]; then
  printf '%s\n' "${DOCKER_AUTH_CONFIG_JSON}" > "${config_path}"
  exit 0
fi

declare -A auths

# Primary / push registry.
if [[ -n "${OCI_USERNAME:-}" && -n "${OCI_TOKEN:-}" ]]; then
  auths["${oci_registry}"]=$(printf '%s:%s' "${OCI_USERNAME}" "${OCI_TOKEN}" | base64 | tr -d '\n')
elif [[ -n "${OCI_DOCKER_AUTH:-}" ]]; then
  auths["${oci_registry}"]="${OCI_DOCKER_AUTH}"
fi

# ghcr.io, independently. Assigned second on purpose: when OCI_REGISTRY is unset both names
# resolve to ghcr.io, and the GHCR_* credentials are the more specific answer for that host.
if [[ -n "${GHCR_USERNAME:-}" && -n "${GHCR_TOKEN:-}" ]]; then
  auths["${ghcr_registry}"]=$(printf '%s:%s' "${GHCR_USERNAME}" "${GHCR_TOKEN}" | base64 | tr -d '\n')
elif [[ -n "${GHCR_DOCKER_AUTH:-}" ]]; then
  auths["${ghcr_registry}"]="${GHCR_DOCKER_AUTH}"
fi

if [[ -n "${DOCKERHUB_USERNAME:-}" && -n "${DOCKERHUB_TOKEN:-}" ]]; then
  auths["${dockerhub_registry}"]=$(printf '%s:%s' "${DOCKERHUB_USERNAME}" "${DOCKERHUB_TOKEN}" | base64 | tr -d '\n')
fi

# Not `(( ${#auths[@]} == 0 ))`: under `set -o nounset` bash 4.4+ treats an empty array as
# unbound, so that form aborted with "auths: unbound variable" and this help text -- the whole
# point of the branch -- never printed. ${auths[*]+x} is the nounset-safe existence test.
if [[ -z "${auths[*]+x}" ]]; then
  cat >&2 <<EOF_ERR
Missing registry credentials.
Provide one of the following before running this script:
  * DOCKER_AUTH_CONFIG_JSON: Full docker config JSON.
  * OCI_DOCKER_AUTH: Base64-encoded "username:token" string for ${oci_registry}.
  * OCI_USERNAME and OCI_TOKEN environment variables.
  * GHCR_DOCKER_AUTH: Base64-encoded "username:token" string for ${ghcr_registry}.
  * GHCR_USERNAME and GHCR_TOKEN environment variables.
Optional (each avoids that registry's anonymous rate limit):
  * GHCR_USERNAME and GHCR_TOKEN -- ghcr.io, source of the CNPG test image.
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
