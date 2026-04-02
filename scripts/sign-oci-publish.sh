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

# Harbor and Kyverno can both resolve Cosign signatures reliably when we use
# legacy referrer mode without tlog bundles for key-based signing.
export COSIGN_DOCKER_MEDIA_TYPES="${COSIGN_DOCKER_MEDIA_TYPES:-1}"
COSIGN_REFERRERS_MODE="${COSIGN_REFERRERS_MODE:-legacy}"
COSIGN_TLOG_UPLOAD="${COSIGN_TLOG_UPLOAD:-false}"

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
  printf '|\n'
}

delete_existing_legacy_signature() {
  local ref="$1"
  local signature_ref repo tag repo_path auth user pass token token_url headers status manifest_digest
  signature_ref="$(cosign triangulate "${ref}")"
  repo="${signature_ref%:*}"
  tag="${signature_ref##*:}"
  repo_path="${repo#${REGISTRY_HOST}/}"
  auth="$(resolve_registry_auth)"
  IFS='|' read -r user pass <<<"${auth}"

  token_url="https://${REGISTRY_HOST}/service/token?service=harbor-registry&scope=repository:${repo_path}:pull,push,delete"
  if [[ -n "${user}" && -n "${pass}" ]]; then
    token="$(curl -fsSL -u "${user}:${pass}" "${token_url}" | jq -r '.token')"
  else
    token="$(curl -fsSL "${token_url}" | jq -r '.token')"
  fi
  [[ -n "${token}" && "${token}" != "null" ]] || return 0

  headers="$(mktemp)"
  status="$(
    curl -sS -o /dev/null -D "${headers}" \
      -H "Authorization: Bearer ${token}" \
      -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
      "https://${REGISTRY_HOST}/v2/${repo_path}/manifests/${tag}" \
      -w '%{http_code}' || true
  )"
  if [[ "${status}" == "404" ]]; then
    rm -f "${headers}"
    return 0
  fi

  manifest_digest="$(awk 'tolower($1)=="docker-content-digest:" {print $2}' "${headers}" | tr -d '\r')"
  rm -f "${headers}"
  [[ -n "${manifest_digest}" ]] || return 0

  curl -fsS -X DELETE \
    -H "Authorization: Bearer ${token}" \
    "https://${REGISTRY_HOST}/v2/${repo_path}/manifests/${manifest_digest}" >/dev/null
}

attach_legacy_signature() {
  local ref="$1"
  local payload_file
  local signature_file
  local bundle_file
  local stdout_file

  payload_file="$(mktemp)"
  signature_file="$(mktemp)"
  bundle_file="$(mktemp)"
  stdout_file="$(mktemp)"

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

  delete_existing_legacy_signature "${ref}"

  cosign attach signature \
    --payload "${payload_file}" \
    --signature "${signature_file}" \
    "${ref}"
  rm -f "${payload_file}" "${signature_file}" "${bundle_file}" "${stdout_file}"
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
