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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY_HOST="${OCI_REGISTRY:-registry.carverauto.dev}"
OCI_PROJECT="${OCI_PROJECT:-serviceradar}"
BAZEL_BIN="${BAZEL_BIN:-$(cd "${REPO_ROOT}" && bazel info bazel-bin 2>/dev/null)}"
IMAGE_METADATA_DIR="${BAZEL_BIN}/docker/images"

# Harbor is storing Cosign signatures as OCI referrer accessories. Force that
# path explicitly so publish and verification use the same storage mode.
export COSIGN_DOCKER_MEDIA_TYPES="${COSIGN_DOCKER_MEDIA_TYPES:-1}"
COSIGN_REFERRERS_MODE="${COSIGN_REFERRERS_MODE:-oci-1-1}"

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
    --registry-referrers-mode="${COSIGN_REFERRERS_MODE}" \
    "${cosign_key_args[@]}" \
    "${ref}"
done

echo "signed OCI images via cosign"
