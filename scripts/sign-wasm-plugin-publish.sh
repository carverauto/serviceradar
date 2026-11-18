#!/usr/bin/env bash
set -euo pipefail

# This credential-bearing launcher must run on the publisher host. Reuse the
# checksum-verified tool installed by harbor-publish.py setup, including when
# release.yml has checked out an older release after setup.
export OCI_PROJECT="${OCI_PROJECT:-serviceradar-builds}"
if [[ "${OCI_PROJECT}" != "serviceradar-builds" ]]; then
  echo "error: direct protected publication is forbidden; use the verified GitHub publishing workflow" >&2
  exit 2
fi
capacity_tool="${HARBOR_LIFECYCLE_DIR:?Run harbor-publish.py setup through the GitHub publishing workflow}/tool/k8s/harbor/promote-artifacts.py"
python3 "${capacity_tool}" --check-capacity-only

# shellcheck source=scripts/cosign_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cosign_common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wasm-plugin-publish-context.sh"
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

ORAS_BIN="$(cosign_resolve_executable oras || true)"
if [[ -z "${ORAS_BIN}" ]]; then
  echo "error: oras is required" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wasm_plugin_publish_init "${REPO_ROOT}"
REGISTRY_HOST="${OCI_REGISTRY:-registry.carverauto.dev}"
OCI_PROJECT="${OCI_PROJECT:-serviceradar-builds}"
COMMIT_TAG="sha-$(git -C "${REPO_ROOT}" rev-parse HEAD)"
# One signature format: the classic `.sig` tag that admission reads, created once per
# digest (no Sigstore bundle referrer), carrying its transparency-log receipt and recorded
# in the signing ledger (attach_legacy_signature in cosign_common.sh).

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

wasm_plugin_publish_build_metadata //build/wasm_plugins:all_metadata

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
    ref="${REGISTRY_HOST}/${OCI_PROJECT}/${repository_name}@${digest}"
    attach_legacy_signature "${ref}"
  done
done
