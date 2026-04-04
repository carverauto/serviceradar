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

if ! command -v oras >/dev/null 2>&1; then
  echo "error: oras is required" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAZEL_BIN="${BAZEL_BIN:-bazel}"
BAZEL_BIN_DIR="${BAZEL_BIN_DIR:-$("${BAZEL_BIN}" info bazel-bin 2>/dev/null)}"
METADATA_DIR="${BAZEL_BIN_DIR}/build/wasm_plugins"
REGISTRY_HOST="${OCI_REGISTRY:-registry.carverauto.dev}"
OCI_PROJECT="${OCI_PROJECT:-serviceradar}"
COMMIT_TAG="sha-$(git -C "${REPO_ROOT}" rev-parse HEAD)"
COSIGN_REFERRERS_MODE="${COSIGN_REFERRERS_MODE:-legacy}"
COSIGN_TLOG_UPLOAD="${COSIGN_TLOG_UPLOAD:-true}"

cosign_key_args=()
if [[ -n "${COSIGN_KEY_FILE:-}" ]]; then
  if [[ ! -f "${COSIGN_KEY_FILE}" ]]; then
    echo "error: COSIGN_KEY_FILE does not exist: ${COSIGN_KEY_FILE}" >&2
    exit 1
  fi
  if [[ -z "${COSIGN_PASSWORD:-}" && -t 0 ]]; then
    read -r -s -p "Cosign password: " COSIGN_PASSWORD
    printf '\n' >&2
    export COSIGN_PASSWORD
  fi
  cosign_key_args+=(--key "${COSIGN_KEY_FILE}")
elif [[ -n "${COSIGN_PRIVATE_KEY:-}" ]]; then
  cosign_key_args+=(--key env://COSIGN_PRIVATE_KEY)
elif [[ "${COSIGN_KEYLESS:-false}" == "true" || -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]]; then
  :
else
  cat >&2 <<'EOF'
error: no cosign signing identity configured.
Set one of:
  COSIGN_KEY_FILE=/path/to/cosign.key
  COSIGN_PRIVATE_KEY='<pem-or-base64-key>'
  COSIGN_KEYLESS=true
EOF
  exit 1
fi

"${BAZEL_BIN}" build //build/wasm_plugins:all_metadata >/dev/null

shopt -s nullglob
metadata_files=("${METADATA_DIR}"/*.metadata.json)
shopt -u nullglob

if [[ ${#metadata_files[@]} -eq 0 ]]; then
  echo "error: no Wasm plugin metadata files found in ${METADATA_DIR}" >&2
  exit 1
fi

for metadata in "${metadata_files[@]}"; do
  repository_name="$(python3 - <<'PY' "${metadata}"
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    print(json.load(fh)["repository_name"])
PY
)"
  ref="${REGISTRY_HOST}/${OCI_PROJECT}/${repository_name}:${COMMIT_TAG}"
  digest="$(oras manifest fetch --descriptor "${ref}" --format json | jq -r '.digest')"
  if [[ -z "${digest}" || "${digest}" == "null" ]]; then
    echo "error: failed to resolve digest for ${ref}" >&2
    exit 1
  fi
  echo "signing ${REGISTRY_HOST}/${OCI_PROJECT}/${repository_name}@${digest}"
  cosign sign \
    --yes \
    --experimental-oci11 \
    --tlog-upload="${COSIGN_TLOG_UPLOAD}" \
    --registry-referrers-mode="${COSIGN_REFERRERS_MODE}" \
    "${cosign_key_args[@]}" \
    "${REGISTRY_HOST}/${OCI_PROJECT}/${repository_name}@${digest}"
done
