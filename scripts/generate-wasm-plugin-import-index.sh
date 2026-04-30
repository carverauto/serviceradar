#!/usr/bin/env bash
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required" >&2
  exit 1
fi

ORAS_BIN="${ORAS_BIN:-oras}"
if ! command -v "${ORAS_BIN}" >/dev/null 2>&1; then
  echo "error: oras is required" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAZEL_BIN="${BAZEL_BIN:-bazel}"
BAZEL_BIN_DIR="${BAZEL_BIN_DIR:-$("${BAZEL_BIN}" info bazel-bin 2>/dev/null)}"
METADATA_DIR="${BAZEL_BIN_DIR}/build/wasm_plugins"
REGISTRY_HOST="${OCI_REGISTRY:-registry.carverauto.dev}"
OCI_PROJECT="${OCI_PROJECT:-serviceradar}"
OUTPUT="${OUTPUT:-${REPO_ROOT}/serviceradar-wasm-plugin-index.json}"

if [[ "$#" -eq 0 ]]; then
  TAG="sha-$(git -C "${REPO_ROOT}" rev-parse HEAD)"
else
  TAG="$1"
fi

"${BAZEL_BIN}" build //build/wasm_plugins:all_metadata >/dev/null

shopt -s nullglob
metadata_files=("${METADATA_DIR}"/*.metadata.json)
shopt -u nullglob

if [[ ${#metadata_files[@]} -eq 0 ]]; then
  echo "error: no Wasm plugin metadata files found in ${METADATA_DIR}" >&2
  exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

printf '{"schema_version":1,"release_tag":%s,"generated_at":%s,"plugins":[' \
  "$(jq -Rn --arg tag "${TAG}" '$tag')" \
  "$(jq -Rn --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '$now')" >"${tmp}"

first=true
for metadata in "${metadata_files[@]}"; do
  repository_name="$(jq -r '.repository_name' "${metadata}")"
  plugin_id="$(jq -r '.plugin_id' "${metadata}")"
  plugin_name="$(jq -r '.plugin_name // .plugin_id' "${metadata}")"
  plugin_version="$(jq -r '.plugin_version // empty' "${metadata}")"
  bundle_media_type="$(jq -r '.bundle_media_type' "${metadata}")"
  upload_signature_media_type="$(jq -r '.upload_signature_media_type' "${metadata}")"
  ref="${REGISTRY_HOST}/${OCI_PROJECT}/${repository_name}:${TAG}"

  descriptor="$("${ORAS_BIN}" manifest fetch --descriptor "${ref}")"
  oci_digest="$(jq -r '.digest' <<<"${descriptor}")"
  manifest="$("${ORAS_BIN}" manifest fetch "${ref}" --format json)"
  content="$(jq -c '.content // .' <<<"${manifest}")"
  bundle_digest="$(jq -r --arg media_type "${bundle_media_type}" '.layers[] | select(.mediaType == $media_type) | .digest' <<<"${content}" | head -n1)"
  upload_signature_digest="$(jq -r --arg media_type "${upload_signature_media_type}" '.layers[] | select(.mediaType == $media_type) | .digest' <<<"${content}" | head -n1)"

  if [[ -z "${oci_digest}" || "${oci_digest}" == "null" || -z "${bundle_digest}" || -z "${upload_signature_digest}" ]]; then
    echo "error: ${ref} is missing required OCI digests" >&2
    exit 1
  fi

  if [[ "${first}" == false ]]; then
    printf ',' >>"${tmp}"
  fi
  first=false

  jq -n \
    --arg plugin_id "${plugin_id}" \
    --arg name "${plugin_name}" \
    --arg version "${plugin_version}" \
    --arg oci_ref "${ref}" \
    --arg oci_digest "${oci_digest}" \
    --arg bundle_digest "${bundle_digest}" \
    --arg upload_signature_digest "${upload_signature_digest}" \
    '{
      plugin_id: $plugin_id,
      name: $name,
      version: $version,
      oci_ref: $oci_ref,
      oci_digest: $oci_digest,
      bundle_digest: $bundle_digest,
      upload_signature_digest: $upload_signature_digest
    }' >>"${tmp}"
done

printf ']}\n' >>"${tmp}"
jq --sort-keys . "${tmp}" >"${OUTPUT}"
echo "wrote ${OUTPUT}"
