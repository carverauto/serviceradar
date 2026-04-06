#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cosign_common.sh"
trap cosign_cleanup_temp_files EXIT

ORAS_BIN="$(cosign_resolve_executable oras || true)"
if [[ -z "${ORAS_BIN}" ]]; then
  echo "error: oras is required" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required" >&2
  exit 1
fi

if ! command -v cosign >/dev/null 2>&1; then
  echo "error: cosign is required" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAZEL_BIN="${BAZEL_BIN:-bazel}"
BAZEL_BIN_DIR="${BAZEL_BIN_DIR:-$("${BAZEL_BIN}" info bazel-bin 2>/dev/null)}"
METADATA_DIR="${BAZEL_BIN_DIR}/build/wasm_plugins"
REGISTRY_HOST="${OCI_REGISTRY:-registry.carverauto.dev}"
OCI_PROJECT="${OCI_PROJECT:-serviceradar}"
TMP_DIR="$(mktemp -d)"

cleanup_verify_wasm() {
  rm -rf "${TMP_DIR}"
}

trap cleanup_verify_wasm EXIT

if [[ "$#" -eq 0 ]]; then
  TAGS=("sha-$(git -C "${REPO_ROOT}" rev-parse HEAD)")
else
  TAGS=("$@")
fi

"${BAZEL_BIN}" build //build/wasm_plugins:all_metadata //build/wasm_plugins:upload_signature_tool >/dev/null

UPLOAD_SIGNATURE_TOOL="$("${BAZEL_BIN}" cquery --output=files //build/wasm_plugins:upload_signature_tool 2>/dev/null | head -n1)"
if [[ -z "${UPLOAD_SIGNATURE_TOOL}" || ! -x "${UPLOAD_SIGNATURE_TOOL}" ]]; then
  echo "error: unable to resolve upload signature tool binary" >&2
  exit 1
fi

shopt -s nullglob
metadata_files=("${METADATA_DIR}"/*.metadata.json)
shopt -u nullglob

if [[ ${#metadata_files[@]} -eq 0 ]]; then
  echo "error: no Wasm plugin metadata files found in ${METADATA_DIR}" >&2
  exit 1
fi

for tag in "${TAGS[@]}"; do
  for metadata in "${metadata_files[@]}"; do
    mapfile -t meta < <(python3 - <<'PY' "${metadata}"
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
print(data["repository_name"])
print(data["artifact_type"])
print(data["bundle_media_type"])
print(data["upload_signature_media_type"])
PY
)
    repository_name="${meta[0]}"
    artifact_type="${meta[1]}"
    bundle_media_type="${meta[2]}"
    upload_signature_media_type="${meta[3]}"
    ref="${REGISTRY_HOST}/${OCI_PROJECT}/${repository_name}:${tag}"

    echo "checking ${ref}"
    manifest="$("${ORAS_BIN}" manifest fetch "${ref}" --format json)"
    actual_artifact_type="$(jq -r '.artifactType // empty' <<<"${manifest}")"
    if [[ "${actual_artifact_type}" != "${artifact_type}" ]]; then
      echo "error: ${ref} artifactType mismatch: expected ${artifact_type}, got ${actual_artifact_type}" >&2
      exit 1
    fi

    jq -e --arg media_type "${bundle_media_type}" '
      any(.layers[]?; .mediaType == $media_type)
    ' <<<"${manifest}" >/dev/null || {
      echo "error: ${ref} is missing an ${bundle_media_type} layer" >&2
      exit 1
    }

    jq -e --arg media_type "${upload_signature_media_type}" '
      any(.layers[]?; .mediaType == $media_type)
    ' <<<"${manifest}" >/dev/null || {
      echo "error: ${ref} is missing an ${upload_signature_media_type} layer" >&2
      exit 1
    }

    bundle_digest="$(jq -r --arg media_type "${bundle_media_type}" '.layers[] | select(.mediaType == $media_type) | .digest' <<<"${manifest}" | head -n1)"
    signature_digest="$(jq -r --arg media_type "${upload_signature_media_type}" '.layers[] | select(.mediaType == $media_type) | .digest' <<<"${manifest}" | head -n1)"

    bundle_path="${TMP_DIR}/${repository_name}-${tag}.zip"
    signature_path="${TMP_DIR}/${repository_name}-${tag}.upload-signature.json"
    "${ORAS_BIN}" blob fetch --output "${bundle_path}" "${REGISTRY_HOST}/${OCI_PROJECT}/${repository_name}@${bundle_digest}" >/dev/null
    "${ORAS_BIN}" blob fetch --output "${signature_path}" "${REGISTRY_HOST}/${OCI_PROJECT}/${repository_name}@${signature_digest}" >/dev/null
    "${UPLOAD_SIGNATURE_TOOL}" verify --bundle "${bundle_path}" --signature "${signature_path}"

    if cosign_init_verify_args; then
      digest="$("${ORAS_BIN}" manifest fetch --descriptor "${ref}" --format json | jq -r '.digest')"
      cosign verify \
        --experimental-oci11 \
        "${COSIGN_VERIFY_ARGS[@]}" \
        "${REGISTRY_HOST}/${OCI_PROJECT}/${repository_name}@${digest}" >/dev/null
    fi
  done
done

echo "verified Wasm plugin OCI artifacts and signatures for tags: ${TAGS[*]}"
