#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 <tag> <file> [asset-name]" >&2
  exit 1
fi

tag="$1"
file_path="$2"
asset_name="${3:-$(basename "${file_path}")}"

if [[ ! -f "${file_path}" ]]; then
  echo "asset not found: ${file_path}" >&2
  exit 1
fi

forgejo_url="${FORGEJO_URL:-https://code.carverauto.dev}"
forgejo_repo="${FORGEJO_REPOSITORY:-carverauto/serviceradar}"
forgejo_token="${FORGEJO_TOKEN:-${GITEA_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}}"

if [[ -z "${forgejo_token}" ]]; then
  echo "FORGEJO_TOKEN (or GITEA_TOKEN/GITHUB_TOKEN/GH_TOKEN) is required" >&2
  exit 1
fi

auth_header="Authorization: token ${forgejo_token}"
accept_header="Accept: application/json"
release_url="${forgejo_url}/api/v1/repos/${forgejo_repo}/releases/tags/${tag}"
releases_url="${forgejo_url}/api/v1/repos/${forgejo_repo}/releases?draft=true&limit=100"

release_json="$(curl -fsSL -H "${accept_header}" -H "${auth_header}" "${release_url}" 2>/dev/null || true)"
release_id="$(jq -r '.id // empty' <<<"${release_json}" 2>/dev/null || true)"
if [[ -z "${release_id}" ]]; then
  releases_json="$(curl -fsSL -H "${accept_header}" -H "${auth_header}" "${releases_url}")"
  release_json="$(jq -c --arg tag "${tag}" 'first(.[] | select(.tag_name == $tag)) // empty' <<<"${releases_json}")"
  release_id="$(jq -r '.id // empty' <<<"${release_json}" 2>/dev/null || true)"
fi
if [[ ! "${release_id}" =~ ^[0-9]+$ ]]; then
  echo "unable to resolve release id for tag ${tag}" >&2
  exit 1
fi

# List responses are not guaranteed to include the complete asset collection.
release_json="$(curl -fsSL \
  -H "${accept_header}" \
  -H "${auth_header}" \
  "${forgejo_url}/api/v1/repos/${forgejo_repo}/releases/${release_id}")"
resolved_release_id="$(jq -r '.id // empty' <<<"${release_json}")"
if [[ "${resolved_release_id}" != "${release_id}" ]]; then
  echo "Forgejo returned an unexpected release while resolving tag ${tag}" >&2
  exit 1
fi

existing_asset_id="$(
  jq -r --arg name "${asset_name}" '.assets[]? | select(.name == $name) | .id' <<<"${release_json}" | head -n1
)"
if [[ -n "${existing_asset_id}" ]]; then
  curl -fsSL -X DELETE \
    -H "${accept_header}" \
    -H "${auth_header}" \
    "${forgejo_url}/api/v1/repos/${forgejo_repo}/releases/${release_id}/assets/${existing_asset_id}" \
    >/dev/null
fi

curl -fsSL \
  -H "${accept_header}" \
  -H "${auth_header}" \
  -F "attachment=@${file_path}" \
  "${forgejo_url}/api/v1/repos/${forgejo_repo}/releases/${release_id}/assets?name=${asset_name}" \
  >/dev/null

echo "uploaded ${asset_name} to release ${tag}"
