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
OCI_PROJECT="${OCI_PROJECT:-serviceradar-builds}"
SIGN_REGISTRY_TAG="${SERVICERADAR_SIGN_REGISTRY_TAG:-}"

if [[ -n "${SERVICERADAR_DOCKERFILE_IMAGE:-}" && -z "${SIGN_REGISTRY_TAG}" ]]; then
  echo "error: a Dockerfile image is signed by its published tag" >&2
  exit 1
fi
if [[ -n "${SERVICERADAR_NATIVE_IMAGE:-}" && -z "${SIGN_REGISTRY_TAG}" ]]; then
  echo "error: a native-build image is signed by its published tag" >&2
  exit 1
fi
if [[ -n "${SERVICERADAR_DOCKERFILE_IMAGE:-}" && -n "${SERVICERADAR_NATIVE_IMAGE:-}" ]]; then
  echo "error: sign one Dockerfile image or one native-build image, not both" >&2
  exit 1
fi

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

# One signature format: the classic `.sig` tag that admission reads, created once per
# digest (no Sigstore bundle referrer), carrying its transparency-log receipt and recorded
# in the signing ledger (attach_legacy_signature in cosign_common.sh).

if [[ -z "${SIGN_REGISTRY_TAG}" && ! -d "${IMAGE_METADATA_DIR}" ]]; then
  echo "error: bazel image metadata directory not found: ${IMAGE_METADATA_DIR}" >&2
  echo "run the Bazel image publish first so index metadata exists locally" >&2
  exit 1
fi

cosign_init_sign_args

sign_image_ref() {
  local ref="$1"

  echo "signing ${ref}"
  attach_legacy_signature "${ref}" || return 1
}

mapfile -t image_rows < <(
  python3 - <<'PY2' "${REPO_ROOT}/docker/images/image_inventory.bzl" "${REGISTRY_HOST}" "${OCI_PROJECT}"
import ast
import os
import re
import sys
from pathlib import Path

inventory_path = Path(sys.argv[1])
registry_host = sys.argv[2]
project = sys.argv[3]
text = inventory_path.read_text()
# One Dockerfile-built infrastructure image, signed by the tag it was just pushed under
# (.github/workflows/publish-dockerfile-image.yml). It must be declared in the inventory.
dockerfile_image = os.environ.get("SERVICERADAR_DOCKERFILE_IMAGE", "")
if dockerfile_image:
    declared = re.search(r"DOCKERFILE_IMAGES\s*=\s*(\[[\s\S]*?\])\n", text)
    names = {entry["repository"] for entry in ast.literal_eval(declared.group(1))} if declared else set()
    if dockerfile_image not in names:
        raise SystemExit(f"unknown Dockerfile image: {dockerfile_image}")
    print(f"{registry_host}/{project}/{dockerfile_image}|")
    raise SystemExit(0)
# One image assembled around a natively built binary (NATIVE_BUILD_IMAGES), signed the same
# way by the tag its workflow just pushed, e.g. .github/workflows/publish-media-worker-cuda.yml.
native_image = os.environ.get("SERVICERADAR_NATIVE_IMAGE", "")
if native_image:
    declared = re.search(r"NATIVE_BUILD_IMAGES\s*=\s*(\[[\s\S]*?\])\n", text)
    names = {entry["repository"] for entry in ast.literal_eval(declared.group(1))} if declared else set()
    if native_image not in names:
        raise SystemExit(f"unknown native-build image: {native_image}")
    print(f"{registry_host}/{project}/{native_image}|")
    raise SystemExit(0)
match = re.search(r"PUBLISHABLE_IMAGES\s*=\s*(\[[\s\S]*?\])\n\n", text)
if not match:
    raise SystemExit(f"unable to parse {inventory_path}")
images = ast.literal_eval(match.group(1))
selected = set(os.environ.get("SERVICERADAR_OCI_REPOSITORIES", "").split())
names = {entry["repository"].split("/")[-1] for entry in images}
if selected - names:
    raise SystemExit(f"unknown OCI repository selection: {' '.join(sorted(selected - names))}")
for entry in images:
    if selected and entry["repository"].split("/")[-1] not in selected:
        continue
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

failed_images=()

for row in "${image_rows[@]}"; do
  IFS='|' read -r repository digest_target <<<"${row}"
  if [[ -n "${SIGN_REGISTRY_TAG}" ]]; then
    if ! digest="$(oci_registry_digest "${repository}:${SIGN_REGISTRY_TAG}")"; then
      echo "error: failed to resolve published OCI digest for ${repository}:${SIGN_REGISTRY_TAG}" >&2
      failed_images+=("${repository}:${SIGN_REGISTRY_TAG}")
      continue
    fi
    digest="$(tr -d '[:space:]' <<<"${digest}")"
    digest_source="published registry tag ${repository}:${SIGN_REGISTRY_TAG}"
  else
    digest_file="${IMAGE_METADATA_DIR}/${digest_target}.json.sha256"
    if [[ ! -f "${digest_file}" ]]; then
      echo "error: missing Bazel OCI digest metadata for ${repository}: ${digest_file}" >&2
      failed_images+=("${repository}")
      continue
    fi
    digest="$(tr -d '[:space:]' < "${digest_file}")"
    digest_source="Bazel OCI digest metadata ${digest_file}"
  fi

  if [[ ! "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "error: invalid digest from ${digest_source}: ${digest}" >&2
    failed_images+=("${repository}")
    continue
  fi

  ref="${repository}@${digest}"
  if ! sign_image_ref "${ref}"; then
    echo "error: failed to sign ${ref}" >&2
    failed_images+=("${ref}")
    continue
  fi
done

if (( ${#failed_images[@]} > 0 )); then
  echo "error: failed to sign ${#failed_images[@]} of ${#image_rows[@]} OCI image(s):" >&2
  for failed_image in "${failed_images[@]}"; do
    echo "  - ${failed_image}" >&2
  done
  exit 1
fi

echo "signed OCI images via cosign"
