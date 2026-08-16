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

token="${FORGEJO_TOKEN:-${GITEA_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}}"
if [[ -z "${token}" ]]; then
  echo "GITHUB_TOKEN (or FORGEJO_TOKEN/GITEA_TOKEN/GH_TOKEN) is required" >&2
  exit 1
fi

# GitHub Actions (and local gh) use the GitHub Releases API. A Forgejo origin
# is used only when FORGEJO_URL is an explicit non-GitHub host.
if [[ -n "${GITHUB_API_URL:-}" || -z "${FORGEJO_URL:-}" || "${FORGEJO_URL}" == *github.com* ]]; then
  api_base="${GITHUB_API_URL:-https://api.github.com}"
  repo="${GITHUB_REPOSITORY:-carverauto/serviceradar}"
  auth_header="Authorization: Bearer ${token}"
  accept_header="Accept: application/vnd.github+json"
  release_url="${api_base}/repos/${repo}/releases/tags/${tag}"
  releases_url="${api_base}/repos/${repo}/releases?per_page=100"
  release_by_id() { echo "${api_base}/repos/${repo}/releases/${1}"; }
  asset_delete() { echo "${api_base}/repos/${repo}/releases/assets/${1}"; }
  asset_upload() {
    echo "https://uploads.github.com/repos/${repo}/releases/${1}/assets?name=${asset_name}"
  }
  github_upload=true
else
  forgejo_url="${FORGEJO_URL}"
  repo="${FORGEJO_REPOSITORY:-carverauto/serviceradar}"
  auth_header="Authorization: token ${token}"
  accept_header="Accept: application/json"
  release_url="${forgejo_url}/api/v1/repos/${repo}/releases/tags/${tag}"
  releases_url="${forgejo_url}/api/v1/repos/${repo}/releases?draft=true&limit=100"
  release_by_id() { echo "${forgejo_url}/api/v1/repos/${repo}/releases/${1}"; }
  asset_delete() { echo "${forgejo_url}/api/v1/repos/${repo}/releases/${release_id}/assets/${1}"; }
  asset_upload() {
    echo "${forgejo_url}/api/v1/repos/${repo}/releases/${1}/assets?name=${asset_name}"
  }
  github_upload=false
fi

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

release_json="$(curl -fsSL -H "${accept_header}" -H "${auth_header}" "$(release_by_id "${release_id}")")"
resolved_release_id="$(jq -r '.id // empty' <<<"${release_json}")"
if [[ "${resolved_release_id}" != "${release_id}" ]]; then
  echo "Release API returned an unexpected release while resolving tag ${tag}" >&2
  exit 1
fi

existing_asset_id="$(
  jq -r --arg name "${asset_name}" '.assets[]? | select(.name == $name) | .id' <<<"${release_json}" | head -n1
)"
if [[ -n "${existing_asset_id}" ]]; then
  curl -fsSL -X DELETE \
    -H "${accept_header}" \
    -H "${auth_header}" \
    "$(asset_delete "${existing_asset_id}")" \
    >/dev/null
fi

if [[ "${github_upload}" == "true" ]]; then
  curl -fsSL \
    -H "${accept_header}" \
    -H "${auth_header}" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@${file_path}" \
    "$(asset_upload "${release_id}")" \
    >/dev/null
else
  curl -fsSL \
    -H "${accept_header}" \
    -H "${auth_header}" \
    -F "attachment=@${file_path}" \
    "$(asset_upload "${release_id}")" \
    >/dev/null
fi

echo "uploaded ${asset_name} to release ${tag}"
