#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${TEST_SRCDIR:-}" && -n "${TEST_WORKSPACE:-}" ]]; then
  repo_root="${TEST_SRCDIR}/${TEST_WORKSPACE}"
else
  repo_root="$(git rev-parse --show-toplevel)"
fi

inventory="${repo_root}/docker/images/image_inventory.bzl"
verify_script="${repo_root}/scripts/verify-oci-publish.sh"
release_workflow="${repo_root}/.forgejo/workflows/release.yml"
cut_release="${repo_root}/scripts/cut-release.sh"
validate_release_tag="${repo_root}/scripts/validate-release-tag.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

SERVICERADAR_IMAGE_INVENTORY="${inventory}" \
  "${verify_script}" --list-image-specs > "${tmp_dir}/actual-specs"

cat > "${tmp_dir}/partial-inventory.bzl" <<'EOF'
PUBLISHABLE_IMAGES = [
    {"image": "first", "repository": "registry.example/serviceradar/first"},
    {"image": "missing-repository"},
]

EOF

if SERVICERADAR_IMAGE_INVENTORY="${tmp_dir}/partial-inventory.bzl" \
  "${verify_script}" --list-image-specs >/dev/null 2>&1; then
  echo "release verifier accepted a partially parsed image inventory" >&2
  exit 1
fi

python3 - "${inventory}" > "${tmp_dir}/expected-specs" <<'PY'
import ast
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
match = re.search(r"PUBLISHABLE_IMAGES\s*=\s*(\[[\s\S]*?\])\n\n", path.read_text())
if not match:
    raise SystemExit(f"unable to parse image inventory: {path}")

for entry in ast.literal_eval(match.group(1)):
    kind = "index" if entry.get("push_image") else "single"
    print(f'{entry["repository"]}|{kind}')
PY

diff -u "${tmp_dir}/expected-specs" "${tmp_dir}/actual-specs"

spec_count="$(wc -l < "${tmp_dir}/actual-specs" | tr -d '[:space:]')"
if [[ "${spec_count}" != "16" ]]; then
  echo "expected 16 release image specs, found ${spec_count}" >&2
  exit 1
fi

for repository in \
  serviceradar-trivy-sidecar \
  serviceradar-datasvc \
  serviceradar-config-updater \
  serviceradar-cert-generator \
  serviceradar-cnpg; do
  if ! grep -Eq "/${repository}\|(single|index)$" "${tmp_dir}/actual-specs"; then
    echo "release verifier inventory is missing ${repository}" >&2
    exit 1
  fi
done

if [[ -n "$(sort "${tmp_dir}/actual-specs" | uniq -d)" ]]; then
  echo "release verifier inventory contains duplicate repositories" >&2
  exit 1
fi

for tag in \
  v0.0.0 \
  v1.4.10 \
  v1.4.11-pre1 \
  v1.4.11-rc2 \
  v1.4.11-alpha3 \
  v1.4.11-beta4; do
  "${validate_release_tag}" "${tag}"
done

invalid_tags=(
  ""
  "1.4.10"
  "v1"
  "v1.4"
  "v1.4.10-pre"
  "v1.4.10-preview1"
  "v01.4.10"
  "v1.04.10"
  "v1.4.010"
  "v1.4.10-pre01"
  "v1.4.10/other"
  "v1.4.10 tag=latest"
  $'v1.4.10\ncommit=deadbeef'
  $'v1.4.10\rtag=latest'
)
for tag in "${invalid_tags[@]}"; do
  if "${validate_release_tag}" "${tag}" >/dev/null 2>&1; then
    printf 'release tag validator accepted invalid tag %q\n' "${tag}" >&2
    exit 1
  fi
done

if "${validate_release_tag}" v1.4.10 unexpected >/dev/null 2>&1; then
  echo "release tag validator accepted extra arguments" >&2
  exit 1
fi

for version in \
  1 \
  1.4 \
  1.4.10-pre \
  1.4.10-preview1 \
  $'1.4.10\ntag=v9.9.9'; do
  if "${cut_release}" \
    --version "${version}" \
    --dry-run \
    --skip-changelog-check >/dev/null 2>&1; then
    printf 'cut-release accepted invalid version %q\n' "${version}" >&2
    exit 1
  fi
done

if "${cut_release}" \
  --version 1.4.10 \
  --tag-prefix release- \
  --dry-run \
  --skip-changelog-check >/dev/null 2>&1; then
  echo "cut-release accepted a tag prefix the workflow cannot publish" >&2
  exit 1
fi

python3 - "${release_workflow}" "${cut_release}" <<'PY'
import sys
from pathlib import Path

workflow = Path(sys.argv[1]).read_text()
cut_release = Path(sys.argv[2]).read_text()

required_workflow_fragments = [
    "id: source",
    'tag="v${version}"',
    "GATED_TAG: ${{ steps.source.outputs.tag }}",
    "GATED_COMMIT: ${{ steps.source.outputs.commit }}",
    'tag="${GATED_TAG}"',
    'release_commit="${GATED_COMMIT}"',
    './scripts/validate-release-tag.sh "${tag}"',
    '''printf 'tag=%s\\ncommit=%s\\n' "${tag}" "${release_commit}" >> "${GITHUB_OUTPUT}"''',
    "id: release_assets",
    "RELEASE_ID: ${{ steps.release_assets.outputs.release_id }}",
    "steps.release.outputs.draft != 'true'",
]
for fragment in required_workflow_fragments:
    if fragment not in workflow:
        raise SystemExit(f"release workflow is missing contract fragment: {fragment}")

if 'tag="$(< VERSION)"' in workflow:
    raise SystemExit("release workflow still derives an unprefixed dispatch tag from VERSION")

source_step = workflow[
    workflow.index("- name: Enforce release source"):
    workflow.index("- name: Cache Bazel artifacts")
]
if 'echo "tag=${tag}"' in source_step:
    raise SystemExit("release workflow writes the validated tag through an unsafe output form")

if '"${script_dir}/validate-release-tag.sh" "${tag}"' not in cut_release:
    raise SystemExit("cut-release does not use the canonical release tag validator")

digest_check = '"${tag_check_script}" "${release_sha_tag}" "${RELEASE_TAG}" latest'
if workflow.count(digest_check) != 2:
    raise SystemExit("release workflow must run the same all-image digest check before and after publish")

postflight = workflow.index("Rechecking release image digest equality after publish/build handling.")
signing = workflow.index("source ./scripts/ci/prepare-openbao-cosign-env.sh")
asset_verification = workflow.index("- name: Verify uploaded release assets via Forgejo API")
finalization = workflow.index("- name: Finalize Forgejo release")
advance = workflow.index("- name: Advance demo release source branch")
if not postflight < signing < asset_verification < finalization < advance:
    raise SystemExit(
        "release digest and asset verification must pass before publication and demo advancement"
    )

dry_run_guard = "if: ${{ steps.release.outputs.dry_run != 'true' }}"
forgejo_release_steps = {
    "asset verification": workflow[asset_verification:finalization],
    "release finalization": workflow[finalization:advance],
}
for step_name, step_body in forgejo_release_steps.items():
    if dry_run_guard not in step_body:
        raise SystemExit(f"dry-run does not skip Forgejo {step_name}")

ancestry_lines = [line for line in cut_release.splitlines() if "git merge-base --is-ancestor" in line]
if len(ancestry_lines) != 1:
    raise SystemExit("cut-release must print exactly one post-merge ancestry command")
if "&& git push origin refs/tags/$tag:refs/tags/$tag" not in ancestry_lines[0]:
    raise SystemExit("cut-release tag push is not mechanically chained to ancestry success")
PY

echo "release publish contracts verified"
