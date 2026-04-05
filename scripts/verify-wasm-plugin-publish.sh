#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cosign_common.sh"
trap cosign_cleanup_temp_files EXIT

if ! command -v oras >/dev/null 2>&1; then
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

if [[ "$#" -eq 0 ]]; then
  TAGS=("sha-$(git -C "${REPO_ROOT}" rev-parse HEAD)")
else
  TAGS=("$@")
fi

"${BAZEL_BIN}" build //build/wasm_plugins:all_metadata >/dev/null

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
PY
)
    repository_name="${meta[0]}"
    artifact_type="${meta[1]}"
    bundle_media_type="${meta[2]}"
    ref="${REGISTRY_HOST}/${OCI_PROJECT}/${repository_name}:${tag}"

    echo "checking ${ref}"
    manifest="$(oras manifest fetch "${ref}" --format json)"
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

    if cosign_init_verify_args; then
      digest="$(oras manifest fetch --descriptor "${ref}" --format json | jq -r '.digest')"
      cosign verify \
        --experimental-oci11 \
        "${COSIGN_VERIFY_ARGS[@]}" \
        "${REGISTRY_HOST}/${OCI_PROJECT}/${repository_name}@${digest}" >/dev/null
    fi
  done
done

echo "verified Wasm plugin OCI artifacts and signatures for tags: ${TAGS[*]}"
