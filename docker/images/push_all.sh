#!/usr/bin/env bash
set -euo pipefail

# --- runfiles setup ---------------------------------------------------------
if [[ -z "${RUNFILES_DIR:-}" && -z "${RUNFILES_MANIFEST_FILE:-}" ]]; then
  if [[ -f "$0.runfiles_manifest" ]]; then
    export RUNFILES_MANIFEST_FILE="$0.runfiles_manifest"
  elif [[ -f "$0.runfiles.MANIFEST" ]]; then
    export RUNFILES_MANIFEST_FILE="$0.runfiles.MANIFEST"
  elif [[ -d "$0.runfiles" ]]; then
    export RUNFILES_DIR="$0.runfiles"
  fi
fi

source "${RUNFILES_DIR:-/dev/null}/bazel_tools/tools/bash/runfiles/runfiles.bash" 2>/dev/null || \
  source "$(grep -sm1 '^bazel_tools/tools/bash/runfiles/runfiles.bash ' "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -d ' ' -f 2)" 2>/dev/null || \
  { echo >&2 "Unable to locate bazel runfiles library"; exit 1; }

workspace="serviceradar"
list_path="$(rlocation "${workspace}/docker/images/ghcr_push_targets.txt")"
if [[ -z "${list_path}" || ! -f "${list_path}" ]]; then
  echo "Failed to locate ghcr_push_targets.txt runfile" >&2
  exit 1
fi

push_targets=()
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" ]] && continue
  push_targets+=("$line")
done < "${list_path}"

registry="${GHCR_REGISTRY:-ghcr.io}"
username="${GHCR_USERNAME:-}"
token="${GHCR_TOKEN:-${GHCR_PAT:-}}"
docker_config_dir="${DOCKER_CONFIG:-}"
temp_dir=""

cleanup() {
  if [[ -n "${temp_dir}" && -d "${temp_dir}" ]]; then
    rm -rf "${temp_dir}"
  fi
}
trap cleanup EXIT

if [[ -n "${username}" && -n "${token}" ]]; then
  temp_dir="$(mktemp -d)"
  export DOCKER_CONFIG="${temp_dir}"
  auth_payload=$(printf '%s:%s' "${username}" "${token}" | base64 | tr -d '\n')
  cat > "${temp_dir}/config.json" <<EOF_CFG
{
  "auths": {
    "${registry}": {
      "auth": "${auth_payload}"
    }
  }
}
EOF_CFG
elif [[ -n "${docker_config_dir}" ]]; then
  if [[ ! -f "${docker_config_dir}/config.json" ]]; then
    echo "DOCKER_CONFIG is set to '${docker_config_dir}' but config.json is missing" >&2
    exit 1
  fi
else
  default_config="${HOME}/.docker/config.json"
  if [[ ! -f "${default_config}" ]]; then
    cat >&2 <<EOF_ERR
No Docker credentials available.
Provide GHCR_USERNAME/GHCR_TOKEN environment variables, set DOCKER_CONFIG to a directory containing config.json, or run buildbuddy_setup_docker_auth.sh beforehand.
EOF_ERR
    exit 1
  fi
fi

for target in "${push_targets[@]}"; do
  push_binary="$(rlocation "${target}")"
  if [[ -z "${push_binary}" || ! -x "${push_binary}" ]]; then
    echo "Unable to locate executable for ${target}" >&2
    exit 1
  fi
  echo "Pushing $(basename "${target}") using registry ${registry}" >&2
  "${push_binary}" "$@"
done
