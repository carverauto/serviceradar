#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cosign_common.sh"
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

ORAS_BIN="$(cosign_resolve_executable oras || true)"
if [[ -z "${ORAS_BIN}" ]]; then
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

"${BAZEL_BIN}" build //build/wasm_plugins:all_metadata >/dev/null

shopt -s nullglob
metadata_files=("${METADATA_DIR}"/*.metadata.json)
shopt -u nullglob

if [[ ${#metadata_files[@]} -eq 0 ]]; then
  echo "error: no Wasm plugin metadata files found in ${METADATA_DIR}" >&2
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
    cosign sign \
      --yes \
      --tlog-upload="${COSIGN_TLOG_UPLOAD}" \
      --registry-referrers-mode="${COSIGN_REFERRERS_MODE}" \
      "${COSIGN_SIGN_ARGS[@]}" \
      "${REGISTRY_HOST}/${OCI_PROJECT}/${repository_name}@${digest}"
  done
done
