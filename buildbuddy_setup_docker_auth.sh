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

# NAME BRIDGE, for the primary registry only.
#
# The two secret stores name one credential differently: BuildBuddy's holds HARBOR_USERNAME /
# HARBOR_TOKEN, Forgejo's holds HARBOR_ROBOT_USERNAME / HARBOR_ROBOT_SECRET and its workflows
# map those to OCI_* in the job `env:` block. Forgejo can do that mapping declaratively;
# BuildBuddy has no job-level env mapping, so its bridge had to be a shell prologue in
# //buildbuddy.yaml -- and a prologue is a place for the checks below to be reimplemented,
# which is exactly what happened. Accepting both names here is what lets that step be one line.
#
# OCI_* WINS. A caller that mapped the names explicitly is stating an intent this fallback must
# not override; it only fills in when neither half of the pair is set.
if [[ -z "${OCI_USERNAME:-}" && -z "${OCI_TOKEN:-}" ]]; then
  OCI_USERNAME="${HARBOR_USERNAME:-}"
  OCI_TOKEN="${HARBOR_TOKEN:-}"
fi

# OCI_AUTH_REQUIRED -- opt-in, and it MUST stay opt-in.
#
# Set it when the caller cannot proceed unauthenticated to the primary registry: it turns two
# silent successes into an immediate, named failure. Without it this script is best-effort by
# design, and two callers depend on that: GitHub pull-request workflows run with no access
# to secrets, where Docker Hub credentials alone are the correct outcome, and
# //build/buildbuddy/release_pipeline.sh invokes the script only `if [[ -x ]]`.
#
# Do NOT infer this from OCI_REGISTRY being set -- fork PRs still have to survive a
# credential-less run.
require_oci_auth="${OCI_AUTH_REQUIRED:-}"

# ...and if it is set, OCI_REGISTRY must be too. `oci_registry` otherwise defaults to ghcr.io,
# which is a REAL registry name, so every check below would be satisfied by credentials written
# under a key the caller never meant -- the exact silent misplacement the flag exists to catch.
# The check this replaced could not see it: it grepped the finished file for ${OCI_REGISTRY},
# so an unset value made it grep for the empty string and match anything.
if [[ -n "${require_oci_auth}" && -z "${OCI_REGISTRY:-}" ]]; then
  echo "OCI_AUTH_REQUIRED is set but OCI_REGISTRY is not." >&2
  echo "Every credential would be written under the ${oci_registry} default instead." >&2
  exit 1
fi

# The early exit below is the first of the two silent successes. On a runner whose image or
# harness already dropped a config.json in place, absent credentials meant "nothing to do" and
# exit 0 -- and the run then died three minutes later in the LOADING phase of the next Bazel
# call, as a 401 on a target that has nothing to do with containers.
if [[ -z "${require_oci_auth}" && -f "${config_path}" && -z "${DOCKER_AUTH_CONFIG_JSON:-}" && -z "${OCI_DOCKER_AUTH:-}" && -z "${OCI_USERNAME:-}" && -z "${OCI_TOKEN:-}" && -z "${GHCR_DOCKER_AUTH:-}" && -z "${GHCR_USERNAME:-}" && -z "${GHCR_TOKEN:-}" ]]; then
  echo "Docker config already present at ${config_path}; nothing to do." >&2
  exit 0
fi

if [[ -n "${DOCKER_AUTH_CONFIG_JSON:-}" ]]; then
  printf '%s\n' "${DOCKER_AUTH_CONFIG_JSON}" > "${config_path}"
  # Opaque blob: this is the one path where the registry keys are not built here, so it is also
  # the one place the check has to be a grep of the result rather than a lookup in `auths`.
  if [[ -n "${require_oci_auth}" ]] && ! grep -q "${oci_registry}" "${config_path}"; then
    echo "DOCKER_AUTH_CONFIG_JSON has no ${oci_registry} entry, and OCI_AUTH_REQUIRED is set." >&2
    exit 1
  fi
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
  * HARBOR_USERNAME and HARBOR_TOKEN -- accepted as OCI_USERNAME/OCI_TOKEN when neither is set.
  * GHCR_DOCKER_AUTH: Base64-encoded "username:token" string for ${ghcr_registry}.
  * GHCR_USERNAME and GHCR_TOKEN environment variables.
Optional (each avoids that registry's anonymous rate limit):
  * GHCR_USERNAME and GHCR_TOKEN -- ghcr.io, source of the CNPG test image.
  * DOCKERHUB_USERNAME and DOCKERHUB_TOKEN environment variables.
EOF_ERR
  exit 1
fi

# The second silent success. Credentials for SOME registry were found, so the block above is
# satisfied and this script used to exit 0 -- even when the one registry the caller actually
# pushes to got no entry, which is the shape the ghcr.io gap had. This is a lookup in `auths`
# rather than a grep of the finished file: the key is the same string the writer below uses, so
# it cannot agree with a substring that came from somewhere else.
if [[ -n "${require_oci_auth}" && -z "${auths["${oci_registry}"]+x}" ]]; then
  cat >&2 <<EOF_ERR
No credentials for ${oci_registry}, and OCI_AUTH_REQUIRED is set.
Set OCI_USERNAME/OCI_TOKEN, HARBOR_USERNAME/HARBOR_TOKEN, or OCI_DOCKER_AUTH.
If credentials ARE set, check OCI_REGISTRY: it defaults to ghcr.io, and everything
would have been written under that key instead.
EOF_ERR
  exit 1
fi

# Registry NAMES only, never the credentials. Without this the only way to tell whether a
# registry ended up authenticated was to infer it from a downstream 403, which is exactly how
# the ghcr.io gap stayed invisible: the step ran, reported success, and wrote a config that
# simply had no ghcr entry.
printf 'Configured docker auth for: %s\n' "${!auths[*]}" >&2

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
