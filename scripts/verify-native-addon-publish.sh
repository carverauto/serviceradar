#!/usr/bin/env bash
# Verify-before-release for native add-on OCI artifacts (issue 3425,
# add-native-addon-build-signing §2.4). Adapted from verify-wasm-plugin-publish.sh:
# checks artifactType, the bundle layer, and the Cosign signature, and verifies
# every per-arch pushed-artifact tarball against its agent-release ed25519
# signature (the signature the agent itself checks on fetch).
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cosign_common.sh"
trap cosign_cleanup_temp_files EXIT

ORAS_BIN="$(cosign_resolve_executable oras || true)"
if [[ -z "${ORAS_BIN}" ]]; then
  echo "error: oras is required" >&2
  exit 1
fi
for tool in jq cosign; do
  command -v "${tool}" >/dev/null 2>&1 || { echo "error: ${tool} is required" >&2; exit 1; }
done

_ARTIFACT_MEDIA_TYPE="application/vnd.serviceradar.native-addon.artifact.v1+gzip"
_ARTIFACT_SIGNATURE_MEDIA_TYPE="application/vnd.serviceradar.native-addon.artifact-signature.v1+hex"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAZEL_BIN="${BAZEL_BIN:-bazel}"
read -r -a BAZEL_BUILD_FLAGS <<<"${BAZEL_BUILD_FLAGS:--c opt}"
BAZEL_BIN_DIR="${BAZEL_BIN_DIR:-$("${BAZEL_BIN}" info "${BAZEL_BUILD_FLAGS[@]}" bazel-bin 2>/dev/null)}"
METADATA_DIR="${METADATA_DIR:-${BAZEL_BIN_DIR}/build/native_addons}"
REGISTRY_HOST="${OCI_REGISTRY:-registry.carverauto.dev}"
OCI_PROJECT="${OCI_PROJECT:-serviceradar}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

if [[ "$#" -eq 0 ]]; then
  TAGS=("sha-$(git -C "${REPO_ROOT}" rev-parse HEAD)")
else
  TAGS=("$@")
fi

"${BAZEL_BIN}" build "${BAZEL_BUILD_FLAGS[@]}" \
  //build/native_addons:all_metadata \
  //build/native_addons:addon_artifact_signature_tool >/dev/null

resolve_tool() {
  local label="$1" name="$2" resolved
  resolved="$("${BAZEL_BIN}" cquery --output=files "${label}" 2>/dev/null | head -n1)"
  if [[ -n "${resolved}" && ! -x "${resolved}" && -x "${BAZEL_BIN_DIR}/${resolved}" ]]; then
    resolved="${BAZEL_BIN_DIR}/${resolved}"
  fi
  if [[ -z "${resolved}" || ! -x "${resolved}" ]]; then
    resolved="$(find "${BAZEL_BIN_DIR}" -type f -name "${name}" -perm -111 2>/dev/null | head -n1)"
  fi
  [[ -n "${resolved}" && -x "${resolved}" ]] || { echo "error: unable to resolve ${name}" >&2; exit 1; }
  printf '%s\n' "${resolved}"
}

ARTIFACT_SIGNATURE_TOOL="$(resolve_tool //build/native_addons:addon_artifact_signature_tool addon_artifact_signature_tool)"

shopt -s nullglob
metadata_files=("${METADATA_DIR}"/*.metadata.json)
shopt -u nullglob
if [[ ${#metadata_files[@]} -eq 0 ]]; then
  echo "error: no native add-on metadata files found in ${METADATA_DIR}" >&2
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
    repo="${REGISTRY_HOST}/${OCI_PROJECT}/${repository_name}"
    ref="${repo}:${tag}"

    echo "checking ${ref}"
    manifest="$("${ORAS_BIN}" manifest fetch "${ref}" --format json)"
    content="$(jq -c '.content // .' <<<"${manifest}")"

    actual_artifact_type="$(jq -r '.artifactType // .config.mediaType // empty' <<<"${content}")"
    if [[ "${actual_artifact_type}" != "${artifact_type}" ]]; then
      echo "error: ${ref} artifactType mismatch: expected ${artifact_type}, got ${actual_artifact_type}" >&2
      exit 1
    fi

    jq -e --arg m "${bundle_media_type}" 'any(.layers[]?; .mediaType == $m)' <<<"${content}" >/dev/null || {
      echo "error: ${ref} is missing a ${bundle_media_type} bundle layer" >&2
      exit 1
    }

    # Per-arch pushed-artifact tarballs: verify each tarball against its agent-release
    # ed25519 signature, pairing layers by title (<tarball> and <tarball>.sig).
    artifact_count=0
    while IFS=$'\t' read -r title digest; do
      [[ -n "${title}" ]] || continue
      sig_digest="$(jq -r --arg t "${title}.sig" --arg m "${_ARTIFACT_SIGNATURE_MEDIA_TYPE}" \
        '.layers[] | select(.mediaType == $m and (.annotations["org.opencontainers.image.title"] == $t)) | .digest' <<<"${content}" | head -n1)"
      if [[ -z "${sig_digest}" || "${sig_digest}" == "null" ]]; then
        echo "error: ${ref} artifact ${title} is missing its signature layer" >&2
        exit 1
      fi
      tarball_path="${TMP_DIR}/${title}"
      sig_path="${TMP_DIR}/${title}.sig"
      "${ORAS_BIN}" blob fetch --output "${tarball_path}" "${repo}@${digest}" >/dev/null
      "${ORAS_BIN}" blob fetch --output "${sig_path}" "${repo}@${sig_digest}" >/dev/null
      "${ARTIFACT_SIGNATURE_TOOL}" verify --artifact "${tarball_path}" --signature "@${sig_path}"
      artifact_count=$((artifact_count + 1))
    done < <(jq -r --arg m "${_ARTIFACT_MEDIA_TYPE}" \
      '.layers[] | select(.mediaType == $m) | [.annotations["org.opencontainers.image.title"], .digest] | @tsv' <<<"${content}")
    if ((artifact_count == 0)); then
      echo "error: ${ref} has no per-arch native add-on artifact layers" >&2
      exit 1
    fi
    echo "  verified ${artifact_count} per-arch artifact signature(s)"

    if cosign_init_verify_args; then
      digest="$("${ORAS_BIN}" manifest fetch --descriptor "${ref}" | jq -r '.digest')"
      cosign verify --experimental-oci11 "${COSIGN_VERIFY_ARGS[@]}" "${repo}@${digest}" >/dev/null
    fi
  done
done

echo "verified native add-on OCI artifacts and signatures for tags: ${TAGS[*]}"
