#!/usr/bin/env bash
# Cosign-signs the published native add-on OCI artifacts (issue 3425,
# add-native-addon-build-signing §2.1). Adapted from sign-wasm-plugin-publish.sh:
# identical OCI/cosign mechanics (OCI 1.1 referrer signature + a legacy detached
# signature, so the WASM-derived verify-then-mirror importer accepts it), only the
# metadata source differs (//build/native_addons:all_metadata). Per-arch
# agent-release ed25519 signatures are produced at push time
# (build/native_addons/publish_addon.sh); the bundle is covered by the Cosign
# signature over the OCI artifact.
set -euo pipefail

# shellcheck source=scripts/cosign_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cosign_common.sh"
trap cosign_cleanup_temp_files EXIT

for tool in cosign python3 jq curl; do
  command -v "${tool}" >/dev/null 2>&1 || { echo "error: ${tool} is required" >&2; exit 1; }
done

ORAS_BIN="$(cosign_resolve_executable oras || true)"
if [[ -z "${ORAS_BIN}" ]]; then
  echo "error: oras is required" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAZEL_BIN="${BAZEL_BIN:-bazel}"
read -r -a BAZEL_BUILD_FLAGS <<<"${BAZEL_BUILD_FLAGS:--c opt}"
BAZEL_BIN_DIR="${BAZEL_BIN_DIR:-$("${BAZEL_BIN}" info "${BAZEL_BUILD_FLAGS[@]}" bazel-bin 2>/dev/null)}"
METADATA_DIR="${METADATA_DIR:-${BAZEL_BIN_DIR}/build/native_addons}"
REGISTRY_HOST="${OCI_REGISTRY:-registry.carverauto.dev}"
OCI_PROJECT="${OCI_PROJECT:-serviceradar}"
COMMIT_TAG="sha-$(git -C "${REPO_ROOT}" rev-parse HEAD)"
export COSIGN_DOCKER_MEDIA_TYPES="${COSIGN_DOCKER_MEDIA_TYPES:-1}"
COSIGN_REFERRERS_MODE="${COSIGN_REFERRERS_MODE:-oci-1-1}"
COSIGN_TLOG_UPLOAD="${COSIGN_TLOG_UPLOAD:-true}"
if [[ "${COSIGN_REFERRERS_MODE}" == "oci-1-1" ]]; then
  export COSIGN_EXPERIMENTAL="${COSIGN_EXPERIMENTAL:-1}"
fi

if [[ "$#" -eq 0 ]]; then
  TAGS=("${COMMIT_TAG}")
else
  TAGS=("$@")
fi

declare -A seen_tags=()
deduped_tags=()
for tag in "${TAGS[@]}"; do
  if [[ -n "${tag}" && -z "${seen_tags[${tag}]+x}" ]]; then
    deduped_tags+=("${tag}")
    seen_tags["${tag}"]=1
  fi
done

cosign_init_sign_args

resolve_registry_auth() {
  if [[ -n "${OCI_USERNAME:-}" && -n "${OCI_TOKEN:-}" ]]; then
    printf '%s|%s\n' "${OCI_USERNAME}" "${OCI_TOKEN}"
    return 0
  fi
  if [[ -n "${HARBOR_ROBOT_USERNAME:-}" && -n "${HARBOR_ROBOT_SECRET:-}" ]]; then
    printf '%s|%s\n' "${HARBOR_ROBOT_USERNAME}" "${HARBOR_ROBOT_SECRET}"
    return 0
  fi
  if [[ -n "${HARBOR_USERNAME:-}" && -n "${HARBOR_PASSWORD:-}" ]]; then
    printf '%s|%s\n' "${HARBOR_USERNAME}" "${HARBOR_PASSWORD}"
    return 0
  fi

  local docker_config
  docker_config="${DOCKER_CONFIG:-${HOME}/.docker}/config.json"
  if [[ -f "${docker_config}" ]]; then
    python3 - <<'PY' "${docker_config}" "${REGISTRY_HOST}"
import base64
import json
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
registry_host = sys.argv[2]
config = json.loads(config_path.read_text())
auths = config.get("auths") or {}
entry = auths.get(registry_host) or auths.get(f"https://{registry_host}") or {}
auth = entry.get("auth") or ""
if auth:
    decoded = base64.b64decode(auth).decode("utf-8")
    user, _, password = decoded.partition(":")
    print(f"{user}|{password}")
else:
    print("|")
PY
    return 0
  fi

  printf '|\n'
}

fetch_registry_token() {
  local repo_path="$1"
  local scope_actions="${2:-pull,push}"
  local auth user pass
  auth="$(resolve_registry_auth)"
  IFS='|' read -r user pass <<<"${auth}"

  local token_url="https://${REGISTRY_HOST}/service/token?service=harbor-registry&scope=repository:${repo_path}:${scope_actions}"
  if [[ -n "${user}" && -n "${pass}" ]]; then
    curl -fsSL -u "${user}:${pass}" "${token_url}" | jq -r '.token'
  else
    curl -fsSL "${token_url}" | jq -r '.token'
  fi
}

upload_blob() {
  local repo_path="$1"
  local file_path="$2"
  local token digest status upload_url patch_headers

  token="$(fetch_registry_token "${repo_path}" "pull,push")"
  [[ -n "${token}" && "${token}" != "null" ]] || {
    echo "error: registry token lookup failed for ${repo_path}" >&2
    return 1
  }

  digest="sha256:$(shasum -a 256 "${file_path}" | awk '{print $1}')"
  status="$(
    curl -sS -o /dev/null \
      -H "Authorization: Bearer ${token}" \
      -I "https://${REGISTRY_HOST}/v2/${repo_path}/blobs/${digest}" \
      -w '%{http_code}' || true
  )"
  if [[ "${status}" == "200" ]]; then
    printf '%s\n' "${digest}"
    return 0
  fi

  upload_url="$(
    curl -fsSI -X POST \
      -H "Authorization: Bearer ${token}" \
      "https://${REGISTRY_HOST}/v2/${repo_path}/blobs/uploads/" \
      | awk 'tolower($1)=="location:" {print $2}' \
      | tr -d '\r'
  )"
  [[ -n "${upload_url}" ]] || {
    echo "error: failed to start blob upload for ${repo_path}" >&2
    return 1
  }
  case "${upload_url}" in
    http*) ;;
    /*) upload_url="https://${REGISTRY_HOST}${upload_url}" ;;
    *) upload_url="https://${REGISTRY_HOST}/${upload_url}" ;;
  esac

  patch_headers="$(mktemp)"
  curl -fsS -D "${patch_headers}" -X PATCH \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/octet-stream' \
    --data-binary @"${file_path}" \
    "${upload_url}" >/dev/null
  upload_url="$(awk 'tolower($1)=="location:" {print $2}' "${patch_headers}" | tr -d '\r')"
  rm -f "${patch_headers}"
  [[ -n "${upload_url}" ]] || {
    echo "error: registry did not return upload location for ${repo_path}" >&2
    return 1
  }
  case "${upload_url}" in
    http*) ;;
    /*) upload_url="https://${REGISTRY_HOST}${upload_url}" ;;
    *) upload_url="https://${REGISTRY_HOST}/${upload_url}" ;;
  esac
  if [[ "${upload_url}" == *\?* ]]; then
    upload_url="${upload_url}&digest=${digest}"
  else
    upload_url="${upload_url}?digest=${digest}"
  fi

  curl -fsS -X PUT \
    -H "Authorization: Bearer ${token}" \
    "${upload_url}" >/dev/null
  printf '%s\n' "${digest}"
}

put_manifest_tag() {
  local repo_path="$1"
  local tag="$2"
  local manifest_file="$3"
  local token

  token="$(fetch_registry_token "${repo_path}" "pull,push")"
  [[ -n "${token}" && "${token}" != "null" ]] || {
    echo "error: registry token lookup failed for ${repo_path}" >&2
    return 1
  }

  curl -fsS -X PUT \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/vnd.oci.image.manifest.v1+json' \
    --data-binary @"${manifest_file}" \
    "https://${REGISTRY_HOST}/v2/${repo_path}/manifests/${tag}" >/dev/null
}

legacy_signature_tag_exists() {
  local repo_path="$1"
  local tag="$2"
  local token status
  token="$(fetch_registry_token "${repo_path}" "pull")"
  [[ -n "${token}" && "${token}" != "null" ]] || return 1
  status="$(
    curl -sS -o /dev/null \
      -H "Authorization: Bearer ${token}" \
      -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
      -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
      -I "https://${REGISTRY_HOST}/v2/${repo_path}/manifests/${tag}" \
      -w '%{http_code}' || true
  )"
  [[ "${status}" == "200" ]]
}

extract_detached_signature() {
  local signature_file="$1"
  local stdout_file="$2"
  local bundle_file="$3"
  local candidate=""

  if [[ -s "${signature_file}" ]]; then
    candidate="$(tr -d '\r\n' <"${signature_file}")"
  fi

  if [[ -z "${candidate}" && -s "${stdout_file}" ]]; then
    candidate="$(tr -d '\r\n' <"${stdout_file}")"
  fi

  if [[ ! "${candidate}" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] && [[ -s "${bundle_file}" ]]; then
    candidate="$(
      jq -r '
        .messageSignature.signature
        // .base64Signature
        // .Base64Signature
        // .dsseEnvelope.signatures[0].sig
        // empty
      ' "${bundle_file}"
    )"
  fi

  if [[ ! "${candidate}" =~ ^[A-Za-z0-9+/]+={0,2}$ ]]; then
    return 1
  fi

  printf '%s\n' "${candidate}"
}

attach_legacy_signature() {
  local ref="$1"
  local repo="${ref%@*}"
  local repo_path="${repo#"${REGISTRY_HOST}"/}"
  local signature_ref signature_tag
  local payload_file signature_file bundle_file stdout_file extracted_signature_file config_file manifest_file
  local payload_digest payload_size config_digest config_size

  signature_ref="$(cosign triangulate "${ref}")"
  signature_tag="${signature_ref##*:}"

  # Classic cosign tags are content-addressed by digest. Harbor immutability
  # rejects overwriting them on a release retry.
  if legacy_signature_tag_exists "${repo_path}" "${signature_tag}"; then
    echo "legacy cosign signature tag ${repo}:${signature_tag} already present; skipping re-push"
    return 0
  fi

  payload_file="$(mktemp)"
  signature_file="$(mktemp)"
  bundle_file="$(mktemp)"
  stdout_file="$(mktemp)"
  extracted_signature_file="$(mktemp)"
  config_file="$(mktemp)"
  manifest_file="$(mktemp)"

  cosign generate "${ref}" >"${payload_file}"
  cosign_sign_blob_to_files \
    "${payload_file}" \
    "${bundle_file}" \
    "${signature_file}" \
    "${stdout_file}" \
    "${COSIGN_TLOG_UPLOAD}"

  if ! extract_detached_signature "${signature_file}" "${stdout_file}" "${bundle_file}" >"${extracted_signature_file}"; then
    echo "error: detached cosign signature was empty for ${ref}" >&2
    exit 1
  fi
  cp "${extracted_signature_file}" "${signature_file}"

  payload_digest="sha256:$(shasum -a 256 "${payload_file}" | awk '{print $1}')"
  payload_size="$(wc -c <"${payload_file}" | tr -d ' ')"

  cat >"${config_file}" <<EOF
{"architecture":"","created":"0001-01-01T00:00:00Z","history":[{"created":"0001-01-01T00:00:00Z"}],"os":"","rootfs":{"type":"layers","diff_ids":["${payload_digest}"]},"config":{}}
EOF
  config_digest="sha256:$(shasum -a 256 "${config_file}" | awk '{print $1}')"
  config_size="$(wc -c <"${config_file}" | tr -d ' ')"

  upload_blob "${repo_path}" "${config_file}" >/dev/null
  upload_blob "${repo_path}" "${payload_file}" >/dev/null

  cat >"${manifest_file}" <<EOF
{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","size":${config_size},"digest":"${config_digest}"},"layers":[{"mediaType":"application/vnd.dev.cosign.simplesigning.v1+json","size":${payload_size},"digest":"${payload_digest}","annotations":{"dev.cosignproject.cosign/signature":"$(cat "${signature_file}")"}}]}
EOF

  put_manifest_tag "${repo_path}" "${signature_tag}" "${manifest_file}"
  rm -f "${payload_file}" "${signature_file}" "${bundle_file}" "${stdout_file}" "${extracted_signature_file}" "${config_file}" "${manifest_file}"
}

"${BAZEL_BIN}" build "${BAZEL_BUILD_FLAGS[@]}" //build/native_addons:all_metadata >/dev/null

shopt -s nullglob
metadata_files=("${METADATA_DIR}"/*.metadata.json)
shopt -u nullglob

if [[ ${#metadata_files[@]} -eq 0 ]]; then
  echo "error: no native add-on metadata files found in ${METADATA_DIR}" >&2
  exit 1
fi

for tag in "${deduped_tags[@]}"; do
  for metadata in "${metadata_files[@]}"; do
    repository_name="$(python3 - <<'PY' "${metadata}"
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    print(json.load(fh)["repository_name"])
PY
)"
    ref="${REGISTRY_HOST}/${OCI_PROJECT}/${repository_name}:${tag}"
    digest="$("${ORAS_BIN}" manifest fetch --descriptor "${ref}" | jq -r '.digest')"
    if [[ -z "${digest}" || "${digest}" == "null" ]]; then
      echo "error: failed to resolve digest for ${ref}" >&2
      exit 1
    fi
    echo "signing ${REGISTRY_HOST}/${OCI_PROJECT}/${repository_name}@${digest}"
    ref="${REGISTRY_HOST}/${OCI_PROJECT}/${repository_name}@${digest}"
    cosign_sign_ref_idempotent "${ref}"
    attach_legacy_signature "${ref}"
  done
done
