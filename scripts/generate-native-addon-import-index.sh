#!/usr/bin/env bash
# Generates serviceradar-native-addon-index.json, the discovery index the
# control-plane importer ingests (issue 3425, add-native-addon-build-signing §2.3).
# Adapted from generate-wasm-plugin-import-index.sh; each entry additionally
# carries a per-arch artifacts[] list (os/arch + the bare-binary sha256 and the
# pushed-artifact tarball's sha256, OCI layer digest, and signature layer digest)
# so the importer can mirror and record each per-arch artifact + its agent-release
# signature on the AddonPackage.
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required" >&2
  exit 1
fi

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cosign_common.sh"

ORAS_BIN="$(cosign_resolve_executable "${ORAS_BIN:-oras}" || true)"
if [[ -z "${ORAS_BIN}" ]]; then
  echo "error: oras is required" >&2
  exit 1
fi

_ARTIFACT_MEDIA_TYPE="application/vnd.serviceradar.native-addon.artifact.v1+gzip"
_ARTIFACT_SIGNATURE_MEDIA_TYPE="application/vnd.serviceradar.native-addon.artifact-signature.v1+hex"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAZEL_BIN="${BAZEL_BIN:-bazel}"
read -r -a BAZEL_BUILD_FLAGS <<<"${BAZEL_BUILD_FLAGS:--c opt}"
BAZEL_BIN_DIR="${BAZEL_BIN_DIR:-$("${BAZEL_BIN}" info "${BAZEL_BUILD_FLAGS[@]}" bazel-bin 2>/dev/null)}"
METADATA_DIR="${METADATA_DIR:-${BAZEL_BIN_DIR}/build/native_addons}"
REGISTRY_HOST="${OCI_REGISTRY:-registry.carverauto.dev}"
OCI_PROJECT="${OCI_PROJECT:-serviceradar}"
OUTPUT="${OUTPUT:-${REPO_ROOT}/serviceradar-native-addon-index.json}"
GENERATED_AT="${GENERATED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

if [[ "$#" -eq 0 ]]; then
  TAG="sha-$(git -C "${REPO_ROOT}" rev-parse HEAD)"
else
  TAG="$1"
fi

"${BAZEL_BIN}" build "${BAZEL_BUILD_FLAGS[@]}" //build/native_addons:all_metadata >/dev/null

shopt -s nullglob
metadata_files=("${METADATA_DIR}"/*.metadata.json)
shopt -u nullglob
if [[ ${#metadata_files[@]} -eq 0 ]]; then
  echo "error: no native add-on metadata files found in ${METADATA_DIR}" >&2
  exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

printf '{"schema_version":1,"release_tag":%s,"generated_at":%s,"addons":[' \
  "$(jq -Rn --arg tag "${TAG}" '$tag')" \
  "$(jq -Rn --arg now "${GENERATED_AT}" '$now')" >"${tmp}"

first=true
for metadata in "${metadata_files[@]}"; do
  repository_name="$(jq -r '.repository_name' "${metadata}")"
  ref="${REGISTRY_HOST}/${OCI_PROJECT}/${repository_name}:${TAG}"
  bundle_media_type="$(jq -r '.bundle_media_type' "${metadata}")"

  descriptor="$("${ORAS_BIN}" manifest fetch --descriptor "${ref}")"
  oci_digest="$(jq -r '.digest' <<<"${descriptor}")"
  content="$("${ORAS_BIN}" manifest fetch "${ref}" --format json | jq -c '.content // .')"
  bundle_digest="$(jq -r --arg m "${bundle_media_type}" '.layers[] | select(.mediaType == $m) | .digest' <<<"${content}" | head -n1)"

  if [[ -z "${oci_digest}" || "${oci_digest}" == "null" || -z "${bundle_digest}" ]]; then
    echo "error: ${ref} is missing required OCI digests" >&2
    exit 1
  fi

  # Join the per-arch artifacts[] from metadata.json (os/arch/sha256/tarball_sha256)
  # with the matching OCI layer digests (tarball + signature) by tarball file name.
  artifacts="$(jq -c \
    --argjson layers "$(jq -c '.layers' <<<"${content}")" \
    --arg art "${_ARTIFACT_MEDIA_TYPE}" \
    --arg sig "${_ARTIFACT_SIGNATURE_MEDIA_TYPE}" '
      def digest_for($mt; $title):
        ($layers[] | select(.mediaType == $mt and (.annotations["org.opencontainers.image.title"] == $title)) | .digest) // null;
      [ (.artifacts // [])[] | select(.tarball_file != null) | {
          os: .os,
          arch: .arch,
          sha256: .sha256,
          tarball_file: .tarball_file,
          tarball_sha256: .tarball_sha256,
          tarball_digest: digest_for($art; .tarball_file),
          signature_digest: digest_for($sig; (.tarball_file + ".sig"))
        } ]
    ' "${metadata}")"

  [[ "${first}" == false ]] && printf ',' >>"${tmp}"
  first=false

  jq -n \
    --arg addon_id "$(jq -r '.addon_id' "${metadata}")" \
    --arg name "$(jq -r '.name // .addon_id' "${metadata}")" \
    --arg version "$(jq -r '.version // empty' "${metadata}")" \
    --arg oci_ref "${ref}" \
    --arg oci_digest "${oci_digest}" \
    --arg bundle_digest "${bundle_digest}" \
    --argjson artifacts "${artifacts}" \
    '{
      addon_id: $addon_id,
      name: $name,
      version: $version,
      oci_ref: $oci_ref,
      oci_digest: $oci_digest,
      bundle_digest: $bundle_digest,
      artifacts: $artifacts
    }' >>"${tmp}"
done

printf ']}\n' >>"${tmp}"
jq --sort-keys . "${tmp}" >"${OUTPUT}"
echo "wrote ${OUTPUT}"
