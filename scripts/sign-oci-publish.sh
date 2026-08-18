#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090,SC1091
source "${SERVICERADAR_COSIGN_COMMON:-${SCRIPT_DIR}/cosign_common.sh}"
trap cosign_cleanup_temp_files EXIT

if ! command -v cosign >/dev/null 2>&1; then
  echo "error: cosign is required" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "error: curl is required" >&2
  exit 1
fi

REPO_ROOT="${SERVICERADAR_REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
REGISTRY_HOST="${OCI_REGISTRY:-registry.carverauto.dev}"
OCI_PROJECT="${OCI_PROJECT:-serviceradar}"
SIGN_REGISTRY_TAG="${SERVICERADAR_SIGN_REGISTRY_TAG:-}"

if [[ -n "${SIGN_REGISTRY_TAG}" ]]; then
  if [[ ! "${SIGN_REGISTRY_TAG}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "error: invalid registry tag for OCI signing: ${SIGN_REGISTRY_TAG}" >&2
    exit 1
  fi
  if ! command -v oras >/dev/null 2>&1; then
    echo "error: oras is required when signing published registry digests" >&2
    exit 1
  fi
  oci_helper=""
  for candidate in \
    "${SCRIPT_DIR}/oci_registry.sh" \
    "${GITHUB_WORKSPACE:-}/scripts/oci_registry.sh"; do
    if [[ -f "${candidate}" ]]; then
      oci_helper="${candidate}"
      break
    fi
  done
  if [[ -z "${oci_helper}" ]]; then
    echo "error: oci_registry.sh not found" >&2
    exit 1
  fi
  # shellcheck source=scripts/oci_registry.sh
  source "${oci_helper}"
  IMAGE_METADATA_DIR=""
else
  BAZEL_BIN="${BAZEL_BIN:-$(cd "${REPO_ROOT}" && bazel info bazel-bin 2>/dev/null)}"
  IMAGE_METADATA_DIR="${BAZEL_BIN}/docker/images"
fi

# Harbor verification checks the OCI referrers API for the signature accessory,
# while older consumers still rely on classic cosign signature tags below.
# Keep tlog upload enabled by default so local publish matches cluster policy.
export COSIGN_DOCKER_MEDIA_TYPES="${COSIGN_DOCKER_MEDIA_TYPES:-1}"
COSIGN_REFERRERS_MODE="${COSIGN_REFERRERS_MODE:-oci-1-1}"
COSIGN_TLOG_UPLOAD="${COSIGN_TLOG_UPLOAD:-true}"
if [[ "${COSIGN_REFERRERS_MODE}" == "oci-1-1" ]]; then
  export COSIGN_EXPERIMENTAL="${COSIGN_EXPERIMENTAL:-1}"
fi

if [[ -z "${SIGN_REGISTRY_TAG}" && ! -d "${IMAGE_METADATA_DIR}" ]]; then
  echo "error: bazel image metadata directory not found: ${IMAGE_METADATA_DIR}" >&2
  echo "run the Bazel image publish first so index metadata exists locally" >&2
  exit 1
fi

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
  local token
  token="$(fetch_registry_token "${repo_path}" "pull,push")"
  [[ -n "${token}" && "${token}" != "null" ]] || {
    echo "error: registry token lookup failed for ${repo_path}" >&2
    return 1
  }

  local digest
  digest="sha256:$(shasum -a 256 "${file_path}" | awk '{print $1}')"
  local status
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

  local upload_url
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

  local patch_headers
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

# Returns 0 when a manifest already exists at repo_path:tag. Used to make the
# legacy signature publish idempotent: the classic cosign signature tag is
# content-addressed by the image digest, so it is identical across release
# re-runs. Harbor tag-immutability rejects overwriting it (HTTP 403), so an
# existing tag must be treated as already-published instead of re-pushed.
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
  local digest="${ref##*@}"
  local repo_path="${repo#"${REGISTRY_HOST}"/}"
  local signature_ref signature_tag
  local payload_file
  local signature_file
  local bundle_file
  local stdout_file
  local extracted_signature_file
  local config_file
  local manifest_file
  local payload_digest payload_size config_digest config_size

  signature_ref="$(cosign triangulate "${ref}")"
  signature_tag="${signature_ref##*:}"

  # The modern OCI signature accessory (cosign_sign_ref_idempotent) above is
  # pushed idempotently. The classic signature tag is content-addressed by the
  # image digest, so an existing one is already valid for this digest. Skipping
  # the re-push avoids overwriting an immutable Harbor tag (HTTP 403), which
  # otherwise makes every release re-run fail here.
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

  # Publish a classic cosign signature tag alongside the OCI bundle accessory
  # using a local sign-blob bundle, which works even when cosign does not
  # reliably populate the detached signature file or stdout on this version.
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
  payload_size="$(wc -c < "${payload_file}" | tr -d ' ')"

  cat >"${config_file}" <<EOF
{"architecture":"","created":"0001-01-01T00:00:00Z","history":[{"created":"0001-01-01T00:00:00Z"}],"os":"","rootfs":{"type":"layers","diff_ids":["${payload_digest}"]},"config":{}}
EOF
  config_digest="sha256:$(shasum -a 256 "${config_file}" | awk '{print $1}')"
  config_size="$(wc -c < "${config_file}" | tr -d ' ')"

  upload_blob "${repo_path}" "${config_file}" >/dev/null
  upload_blob "${repo_path}" "${payload_file}" >/dev/null

  cat >"${manifest_file}" <<EOF
{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","size":${config_size},"digest":"${config_digest}"},"layers":[{"mediaType":"application/vnd.dev.cosign.simplesigning.v1+json","size":${payload_size},"digest":"${payload_digest}","annotations":{"dev.cosignproject.cosign/signature":"$(cat "${signature_file}")"}}]}
EOF

  put_manifest_tag "${repo_path}" "${signature_tag}" "${manifest_file}"
  rm -f "${payload_file}" "${signature_file}" "${bundle_file}" "${stdout_file}" "${extracted_signature_file}" "${config_file}" "${manifest_file}"
}

mapfile -t image_rows < <(
  python3 - <<'PY2' "${REPO_ROOT}/docker/images/image_inventory.bzl" "${REGISTRY_HOST}" "${OCI_PROJECT}"
import ast
import re
import sys
from pathlib import Path

inventory_path = Path(sys.argv[1])
registry_host = sys.argv[2]
project = sys.argv[3]
text = inventory_path.read_text()
match = re.search(r"PUBLISHABLE_IMAGES\s*=\s*(\[[\s\S]*?\])\n\n", text)
if not match:
    raise SystemExit(f"unable to parse {inventory_path}")
images = ast.literal_eval(match.group(1))
for entry in images:
    push_image = entry.get("push_image", entry["image"])
    digest_label = entry.get("digest_label", f":{push_image}.digest")
    if not (digest_label.startswith(":") and digest_label.endswith(".digest")):
        raise SystemExit(f"unsupported digest label format: {digest_label}")
    digest_target = digest_label[1:-len('.digest')]
    repository_name = entry["repository"].split("/")[-1]
    repository = f"{registry_host}/{project}/{repository_name}"
    print(f"{repository}|{digest_target}")
PY2
)

if [[ ${#image_rows[@]} -eq 0 ]]; then
  echo "error: no publishable images found" >&2
  exit 1
fi

for row in "${image_rows[@]}"; do
  IFS='|' read -r repository digest_target <<<"${row}"
  if [[ -n "${SIGN_REGISTRY_TAG}" ]]; then
    if ! digest="$(oci_registry_digest "${repository}:${SIGN_REGISTRY_TAG}")"; then
      echo "error: failed to resolve published OCI digest for ${repository}:${SIGN_REGISTRY_TAG}" >&2
      exit 1
    fi
    digest="$(tr -d '[:space:]' <<<"${digest}")"
    digest_source="published registry tag ${repository}:${SIGN_REGISTRY_TAG}"
  else
    digest_file="${IMAGE_METADATA_DIR}/${digest_target}.json.sha256"
    if [[ ! -f "${digest_file}" ]]; then
      echo "error: missing Bazel OCI digest metadata for ${repository}: ${digest_file}" >&2
      exit 1
    fi
    digest="$(tr -d '[:space:]' < "${digest_file}")"
    digest_source="Bazel OCI digest metadata ${digest_file}"
  fi

  if [[ ! "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "error: invalid digest from ${digest_source}: ${digest}" >&2
    exit 1
  fi

  ref="${repository}@${digest}"
  echo "signing ${ref}"
  cosign_sign_ref_idempotent "${ref}"
  attach_legacy_signature "${ref}"
done

echo "signed OCI images via cosign"
