#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <owner/repository> <release-tag> <import-index>" >&2
  exit 1
fi

repository="$1"
tag="$2"
index_path="$3"
asset_name="serviceradar-wasm-plugin-index.json"
api_root="${GITHUB_API_URL:-https://api.github.com}"
uploads_root="${GITHUB_UPLOADS_URL:-https://uploads.github.com}"
github_token="${EXTERNAL_PLUGIN_GITHUB_PUBLISH_TOKEN:-${GITHUB_TOKEN:-}}"
target_commitish="${EXTERNAL_PLUGIN_TARGET_COMMITISH:-${tag}}"

if [[ ! "${repository}" =~ ^[a-z0-9_.-]+/[a-z0-9_.-]+$ ]]; then
  echo "Invalid GitHub repository: ${repository}" >&2
  exit 1
fi
if [[ ! "${tag}" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
  echo "Invalid external plugin release tag: ${tag}" >&2
  exit 1
fi
if [[ ! "${target_commitish}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "EXTERNAL_PLUGIN_TARGET_COMMITISH must be a lowercase 40-character Git commit" >&2
  exit 1
fi
if [[ ! -s "${index_path}" ]]; then
  echo "Import index is missing or empty: ${index_path}" >&2
  exit 1
fi
if [[ -z "${github_token}" ]]; then
  echo "EXTERNAL_PLUGIN_GITHUB_PUBLISH_TOKEN (or GITHUB_TOKEN) is required" >&2
  exit 1
fi
for command_name in curl jq cmp; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "${command_name} is required" >&2
    exit 1
  }
done

if ! jq -e --arg tag "${tag}" '
  .schema_version == 1 and
  .release_tag == $tag and
  (.plugins | type == "array" and length > 0)
' "${index_path}" >/dev/null; then
  echo "Import index does not match release ${tag}" >&2
  exit 1
fi

api_base="${api_root}/repos/${repository}"
uploads_base="${uploads_root}/repos/${repository}"
auth_header="Authorization: Bearer ${github_token}"
accept_header="Accept: application/vnd.github+json"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fetch_release() {
  local release_json release_id releases_json
  release_json="$(curl -fsS -H "${accept_header}" -H "${auth_header}" \
    "${api_base}/releases/tags/${tag}" 2>/dev/null || true)"
  release_id="$(jq -r '.id // empty' <<<"${release_json}" 2>/dev/null || true)"
  if [[ -n "${release_id}" ]]; then
    printf '%s\n' "${release_json}"
    return 0
  fi

  releases_json="$(curl -fsS -H "${accept_header}" -H "${auth_header}" \
    "${api_base}/releases?per_page=100")"
  jq -c --arg tag "${tag}" \
    'first(.[] | select(.tag_name == $tag)) // empty' <<<"${releases_json}"
}

release_json="$(fetch_release)"
release_id="$(jq -r '.id // empty' <<<"${release_json}" 2>/dev/null || true)"
if [[ -z "${release_id}" ]]; then
  create_payload="$(jq -n \
    --arg tag "${tag}" \
    --arg target "${target_commitish}" \
    '{
      tag_name: $tag,
      target_commitish: $target,
      name: ("ServiceRadar external Wasm plugin " + $tag),
      body: "Protected ServiceRadar external Wasm plugin import index.",
      draft: true,
      prerelease: false
    }')"
  release_json="$(curl -fsS -X POST \
    -H "${accept_header}" \
    -H "${auth_header}" \
    -H 'Content-Type: application/json' \
    --data "${create_payload}" \
    "${api_base}/releases")"
  release_id="$(jq -r '.id // empty' <<<"${release_json}")"
fi

if [[ ! "${release_id}" =~ ^[0-9]+$ ]]; then
  echo "Unable to resolve GitHub release for ${tag}" >&2
  exit 1
fi

release_json="$(curl -fsS -H "${accept_header}" -H "${auth_header}" \
  "${api_base}/releases/${release_id}")"
is_draft="$(jq -r '.draft // false' <<<"${release_json}")"
asset_id="$(jq -r --arg name "${asset_name}" \
  '.assets[]? | select(.name == $name) | .id' <<<"${release_json}" | head -n1)"
asset_url="$(jq -r --arg name "${asset_name}" \
  '.assets[]? | select(.name == $name) | .browser_download_url // empty' \
  <<<"${release_json}" | head -n1)"

if [[ "${is_draft}" != true ]]; then
  if [[ -z "${asset_url}" ]]; then
    echo "Published release ${tag} is missing ${asset_name}" >&2
    exit 1
  fi
  curl -fsS -H "${auth_header}" "${asset_url}" -o "${tmp_dir}/${asset_name}"
  if ! cmp -s "${index_path}" "${tmp_dir}/${asset_name}"; then
    echo "Published release ${tag} contains a different immutable import index" >&2
    exit 1
  fi
  echo "GitHub release ${tag} already contains the verified import index"
  exit 0
fi

if [[ -n "${asset_id}" ]]; then
  curl -fsS -X DELETE -H "${accept_header}" -H "${auth_header}" \
    "${api_base}/releases/assets/${asset_id}" >/dev/null
fi
curl -fsS -X POST \
  -H "${accept_header}" \
  -H "${auth_header}" \
  -H "Content-Type: application/octet-stream" \
  --data-binary "@${index_path}" \
  "${uploads_base}/releases/${release_id}/assets?name=${asset_name}" >/dev/null

release_json="$(curl -fsS -H "${accept_header}" -H "${auth_header}" \
  "${api_base}/releases/${release_id}")"
asset_url="$(jq -r --arg name "${asset_name}" \
  '.assets[]? | select(.name == $name) | .browser_download_url // empty' \
  <<<"${release_json}" | head -n1)"
if [[ -z "${asset_url}" ]]; then
  echo "Import index was not present after upload" >&2
  exit 1
fi
curl -fsS -H "${auth_header}" "${asset_url}" -o "${tmp_dir}/${asset_name}"
if ! cmp -s "${index_path}" "${tmp_dir}/${asset_name}"; then
  echo "Uploaded import index failed byte-for-byte verification" >&2
  exit 1
fi

publish_payload="$(jq -n \
  --arg tag "${tag}" \
  --arg target "${target_commitish}" \
  '{
    tag_name: $tag,
    target_commitish: $target,
    name: ("ServiceRadar external Wasm plugin " + $tag),
    body: "Protected ServiceRadar external Wasm plugin import index.",
    draft: false,
    prerelease: false
  }')"
curl -fsS -X PATCH \
  -H "${accept_header}" \
  -H "${auth_header}" \
  -H 'Content-Type: application/json' \
  --data "${publish_payload}" \
  "${api_base}/releases/${release_id}" >/dev/null

release_json="$(curl -fsS -H "${accept_header}" -H "${auth_header}" \
  "${api_base}/releases/tags/${tag}")"
if [[ "$(jq -r 'if has("draft") then .draft else true end' <<<"${release_json}")" != false ]]; then
  echo "GitHub release ${tag} remained a draft" >&2
  exit 1
fi
if ! jq -e --arg name "${asset_name}" \
  'any(.assets[]?; .name == $name)' <<<"${release_json}" >/dev/null; then
  echo "Published GitHub release ${tag} is missing ${asset_name}" >&2
  exit 1
fi

echo "Published verified GitHub release ${tag}"
