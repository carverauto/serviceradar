#!/usr/bin/env bash
set -euo pipefail

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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY_HOST="${OCI_REGISTRY:-registry.carverauto.dev}"
OCI_PROJECT="${OCI_PROJECT:-serviceradar}"
BAZEL_BIN="${BAZEL_BIN:-$(cd "${REPO_ROOT}" && bazel info bazel-bin 2>/dev/null)}"
IMAGE_METADATA_DIR="${BAZEL_BIN}/docker/images"

# Harbor and Kyverno both accept legacy referrer mode, but the demo admission
# policy also requires signatures to exist in Rekor. Keep tlog upload enabled
# by default so local publish matches cluster enforcement.
export COSIGN_DOCKER_MEDIA_TYPES="${COSIGN_DOCKER_MEDIA_TYPES:-1}"
COSIGN_REFERRERS_MODE="${COSIGN_REFERRERS_MODE:-legacy}"
COSIGN_TLOG_UPLOAD="${COSIGN_TLOG_UPLOAD:-true}"

if [[ ! -d "${IMAGE_METADATA_DIR}" ]]; then
  echo "error: bazel image metadata directory not found: ${IMAGE_METADATA_DIR}" >&2
  echo "run the Bazel image publish first so index metadata exists locally" >&2
  exit 1
fi

cosign_key_args=()

if [[ -n "${COSIGN_KEY_FILE:-}" ]]; then
  if [[ ! -f "${COSIGN_KEY_FILE}" ]]; then
    echo "error: COSIGN_KEY_FILE does not exist: ${COSIGN_KEY_FILE}" >&2
    exit 1
  fi
  if [[ -z "${COSIGN_PASSWORD:-}" && -t 0 ]]; then
    read -r -s -p "Cosign password: " COSIGN_PASSWORD
    printf '\\n' >&2
    export COSIGN_PASSWORD
  fi
  cosign_key_args+=(--key "${COSIGN_KEY_FILE}")
elif [[ -n "${COSIGN_PRIVATE_KEY:-}" ]]; then
  cosign_key_args+=(--key env://COSIGN_PRIVATE_KEY)
elif [[ "${COSIGN_KEYLESS:-false}" == "true" || -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]]; then
  :
else
  cat >&2 <<'MSG'
error: no cosign signing identity configured.
Set one of:
  COSIGN_KEY_FILE=/path/to/cosign.key
  COSIGN_PRIVATE_KEY='<pem-or-base64-key>'
  COSIGN_KEYLESS=true (for ambient keyless/OIDC environments)
MSG
  exit 1
fi

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

attach_legacy_signature() {
  local ref="$1"
  local repo="${ref%@*}"
  local digest="${ref##*@}"
  local repo_path="${repo#${REGISTRY_HOST}/}"
  local signature_ref signature_tag
  local payload_file
  local signature_file
  local bundle_file
  local stdout_file
  local config_file
  local manifest_file
  local payload_digest payload_size config_digest config_size

  signature_ref="$(cosign triangulate "${ref}")"
  signature_tag="${signature_ref##*:}"

  payload_file="$(mktemp)"
  signature_file="$(mktemp)"
  bundle_file="$(mktemp)"
  stdout_file="$(mktemp)"
  config_file="$(mktemp)"
  manifest_file="$(mktemp)"

  # Publish a classic cosign signature tag alongside the OCI bundle accessory
  # using a local sign-blob bundle, which works even when cosign does not
  # reliably populate the detached signature file or stdout on this version.
  cosign generate "${ref}" >"${payload_file}"
  cosign sign-blob \
    --yes \
    --tlog-upload="${COSIGN_TLOG_UPLOAD}" \
    "${cosign_key_args[@]}" \
    --bundle "${bundle_file}" \
    --output-signature "${signature_file}" \
    "${payload_file}" >"${stdout_file}"

  if [[ ! -s "${signature_file}" && -s "${stdout_file}" ]]; then
    cp "${stdout_file}" "${signature_file}"
  fi
  if [[ ! -s "${signature_file}" ]]; then
    jq -r '.messageSignature.signature // .base64Signature // empty' "${bundle_file}" >"${signature_file}"
  fi
  if [[ ! -s "${signature_file}" ]]; then
    echo "error: detached cosign signature was empty for ${ref}" >&2
    exit 1
  fi

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
  rm -f "${payload_file}" "${signature_file}" "${bundle_file}" "${stdout_file}" "${config_file}" "${manifest_file}"
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
  index_json="${IMAGE_METADATA_DIR}/${digest_target}_index.json"
  if [[ ! -f "${index_json}" ]]; then
    echo "error: missing Bazel OCI index metadata for ${repository}: ${index_json}" >&2
    exit 1
  fi

  digest="$(python3 - <<'PY3' "${index_json}"
import json
import sys
from pathlib import Path

index_path = Path(sys.argv[1])
index = json.loads(index_path.read_text())
manifests = index.get("manifests") or []
if not manifests:
    raise SystemExit(f"no manifests in {index_path}")
manifest = manifests[0]
digest = manifest.get("digest")
if not digest:
    raise SystemExit(f"manifest digest missing in {index_path}")
print(digest)
PY3
)"

  ref="${repository}@${digest}"
  echo "signing ${ref}"
  cosign sign \
    --yes \
    --tlog-upload="${COSIGN_TLOG_UPLOAD}" \
    --registry-referrers-mode="${COSIGN_REFERRERS_MODE}" \
    "${cosign_key_args[@]}" \
    "${ref}"

  attach_legacy_signature "${ref}"
done

echo "signed OCI images via cosign"
