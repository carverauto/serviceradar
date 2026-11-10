#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${TEST_SRCDIR:-}" && -n "${TEST_WORKSPACE:-}" ]]; then
  repo_root="${TEST_SRCDIR}/${TEST_WORKSPACE}"
else
  repo_root="$(git rev-parse --show-toplevel)"
fi

inventory="${repo_root}/docker/images/image_inventory.bzl"
verify_script="${repo_root}/scripts/verify-oci-publish.sh"
release_workflow="${repo_root}/.github/workflows/release.yml"
native_addons_workflow="${repo_root}/.github/workflows/native-addons.yml"
wasm_plugins_workflow="${repo_root}/.github/workflows/wasm-plugins.yml"
source_security_workflow="${repo_root}/.github/workflows/source-security.yml"
image_security_workflow="${repo_root}/.github/workflows/image-security.yml"
upload_release_asset="${repo_root}/scripts/upload-forgejo-release-asset.sh"
cut_release="${repo_root}/scripts/cut-release.sh"
validate_release_tag="${repo_root}/scripts/validate-release-tag.sh"
validate_release_metadata="${repo_root}/scripts/validate-release-metadata.sh"
check_oci_chart_version_available="${repo_root}/scripts/check-oci-chart-version-available.sh"
sign_oci_publish="${repo_root}/scripts/sign-oci-publish.sh"
demo_prod_application="${repo_root}/k8s/argocd/applications/demo-prod.yaml"

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

oci_registry_body="$(<"${repo_root}/scripts/oci_registry.sh")"
if [[ "${oci_registry_body}" != *'oras blob fetch --output -'* ]]; then
  echo "oci_registry.sh must pass --output - to oras blob fetch (oras 1.3 requires it)" >&2
  exit 1
fi

verify_body="$(<"${verify_script}")"
for fragment in \
  'source "${SERVICERADAR_COSIGN_COMMON:-${SCRIPT_DIR}/cosign_common.sh}"' \
  'REPO_ROOT="${SERVICERADAR_REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"'; do
  if [[ "${verify_body}" != *"${fragment}"* ]]; then
    echo "verify-oci-publish.sh is missing RUNNER_TEMP-safe contract: ${fragment}" >&2
    exit 1
  fi
done

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

metadata_repo="${tmp_dir}/metadata-repo"
mkdir -p "${metadata_repo}/helm/serviceradar"
git -C "${metadata_repo}" init -q
git -C "${metadata_repo}" config user.name "Release Contract Test"
git -C "${metadata_repo}" config user.email "release-contract@example.invalid"
printf '9.8.7\n' > "${metadata_repo}/VERSION"
cat > "${metadata_repo}/helm/serviceradar/Chart.yaml" <<'EOF'
apiVersion: v2
name: serviceradar
version: 9.8.7
appVersion: "9.8.7"
EOF
git -C "${metadata_repo}" add VERSION helm/serviceradar/Chart.yaml
git -C "${metadata_repo}" commit -qm "matching release metadata"
git -C "${metadata_repo}" update-ref refs/tags/v9.8.7 HEAD

(
  cd "${metadata_repo}"
  "${validate_release_metadata}" v9.8.7 >/dev/null
)

if (
  cd "${metadata_repo}"
  "${validate_release_metadata}" v9.8.8 >/dev/null 2>&1
); then
  echo "release metadata validator accepted a missing tag" >&2
  exit 1
fi

git -C "${metadata_repo}" update-ref refs/tags/v9.8.8 HEAD
if (
  cd "${metadata_repo}"
  "${validate_release_metadata}" v9.8.8 >/dev/null 2>&1
); then
  echo "release metadata validator accepted VERSION/tag disagreement" >&2
  exit 1
fi
git -C "${metadata_repo}" update-ref -d refs/tags/v9.8.8

sed 's/version: 9.8.7/version: 9.8.8/' \
  "${metadata_repo}/helm/serviceradar/Chart.yaml" > "${tmp_dir}/Chart.yaml"
mv "${tmp_dir}/Chart.yaml" "${metadata_repo}/helm/serviceradar/Chart.yaml"
git -C "${metadata_repo}" add helm/serviceradar/Chart.yaml
git -C "${metadata_repo}" commit -qm "mismatched chart metadata"
if (
  cd "${metadata_repo}"
  "${validate_release_metadata}" v9.8.7 HEAD >/dev/null 2>&1
); then
  echo "release metadata validator accepted a source other than the tag target" >&2
  exit 1
fi
git -C "${metadata_repo}" update-ref refs/tags/v9.8.7 HEAD
if (
  cd "${metadata_repo}"
  "${validate_release_metadata}" v9.8.7 >/dev/null 2>&1
); then
  echo "release metadata validator accepted Helm chart/tag disagreement" >&2
  exit 1
fi

cat > "${metadata_repo}/helm/serviceradar/Chart.yaml" <<'EOF'
apiVersion: v2
name: serviceradar
version: 9.8.7
appVersion: "9.8.8"
EOF
git -C "${metadata_repo}" add helm/serviceradar/Chart.yaml
git -C "${metadata_repo}" commit -qm "mismatched application metadata"
git -C "${metadata_repo}" update-ref refs/tags/v9.8.7 HEAD
if (
  cd "${metadata_repo}"
  "${validate_release_metadata}" v9.8.7 >/dev/null 2>&1
); then
  echo "release metadata validator accepted Helm appVersion/tag disagreement" >&2
  exit 1
fi

cat > "${metadata_repo}/helm/serviceradar/Chart.yaml" <<'EOF'
apiVersion: v2
name: serviceradar
version: 9.8.7
appVersion: "9.8.7"
EOF
write_demo_argocd_source() {
  cat > "${metadata_repo}/helm/serviceradar/.argocd-source-serviceradar-demo-prod.yaml" <<EOF
helm:
  parameters:
  - name: global.imageTag
    value: $1
    forcestring: true
  - name: image.name
    value: registry.example.com/serviceradar/serviceradar-web-ng
    forcestring: true
EOF
  git -C "${metadata_repo}" add helm/serviceradar
  git -C "${metadata_repo}" commit -qm "demo source override $1"
  git -C "${metadata_repo}" update-ref refs/tags/v9.8.7 HEAD
}

write_demo_argocd_source v9.8.7
(
  cd "${metadata_repo}"
  "${validate_release_metadata}" v9.8.7 >/dev/null
)

write_demo_argocd_source v9.8.6
if (
  cd "${metadata_repo}"
  "${validate_release_metadata}" v9.8.7 >/dev/null 2>&1
); then
  echo "release metadata validator accepted a demo image tag from another release" >&2
  exit 1
fi

fake_helm="${tmp_dir}/fake-helm.sh"
cat > "${fake_helm}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${FAKE_CHART_PROBE_MODE:-}" in
  available)
    echo 'Error: registry response: MANIFEST_UNKNOWN' >&2
    exit 1
    ;;
  available_not_found)
    echo 'Error: failed to perform "FetchReference" on source: registry.example.invalid/charts/serviceradar:9.8.7: not found' >&2
    exit 1
    ;;
  occupied)
    echo 'apiVersion: v2'
    exit 0
    ;;
  unavailable)
    echo 'Error: dial tcp: registry unavailable' >&2
    exit 1
    ;;
  *)
    echo 'unexpected fake Helm mode' >&2
    exit 3
    ;;
esac
EOF
chmod +x "${fake_helm}"

FAKE_CHART_PROBE_MODE=available \
  SERVICERADAR_HELM_RUNNER="${fake_helm}" \
  "${check_oci_chart_version_available}" 9.8.7 >/dev/null

FAKE_CHART_PROBE_MODE=available_not_found \
  SERVICERADAR_HELM_RUNNER="${fake_helm}" \
  "${check_oci_chart_version_available}" 9.8.7 >/dev/null

ln -s "${fake_helm}" "${tmp_dir}/helm"
env -u CI -u SERVICERADAR_HELM_RUNNER \
  PATH="${tmp_dir}:${PATH}" \
  FAKE_CHART_PROBE_MODE=available_not_found \
  "${check_oci_chart_version_available}" 9.8.7 >/dev/null

if FAKE_CHART_PROBE_MODE=occupied \
  SERVICERADAR_HELM_RUNNER="${fake_helm}" \
  "${check_oci_chart_version_available}" 9.8.7 \
  >"${tmp_dir}/occupied.out" 2>&1; then
  echo "OCI chart occupancy guard accepted an occupied version" >&2
  exit 1
fi
if ! grep -q "select a new product version" "${tmp_dir}/occupied.out"; then
  echo "OCI chart occupancy guard did not explain immutable version recovery" >&2
  exit 1
fi

if FAKE_CHART_PROBE_MODE=unavailable \
  SERVICERADAR_HELM_RUNNER="${fake_helm}" \
  "${check_oci_chart_version_available}" 9.8.7 \
  >"${tmp_dir}/unavailable.out" 2>&1; then
  echo "OCI chart occupancy guard did not fail closed on registry errors" >&2
  exit 1
fi
if ! grep -q "Unable to verify OCI Helm chart occupancy" "${tmp_dir}/unavailable.out"; then
  echo "OCI chart occupancy guard did not report an unverifiable registry" >&2
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

python3 - \
  "${release_workflow}" \
  "${native_addons_workflow}" \
  "${wasm_plugins_workflow}" \
  "${source_security_workflow}" \
  "${image_security_workflow}" \
  "${upload_release_asset}" \
  "${cut_release}" \
  "${sign_oci_publish}" \
  "${demo_prod_application}" <<'PY'
import sys
from pathlib import Path

workflow = Path(sys.argv[1]).read_text()
native_addons_workflow = Path(sys.argv[2]).read_text()
wasm_plugins_workflow = Path(sys.argv[3]).read_text()
source_security_workflow = Path(sys.argv[4]).read_text()
image_security_workflow = Path(sys.argv[5]).read_text()
upload_release_asset = Path(sys.argv[6]).read_text()
cut_release = Path(sys.argv[7]).read_text()
sign_oci_publish = Path(sys.argv[8]).read_text()
demo_prod_application = Path(sys.argv[9]).read_text()

required_workflow_fragments = [
    "id: source",
    'required: true',
    'if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" ]]',
    'git fetch --no-tags origin "refs/tags/${tag}:refs/tags/${tag}"',
    'elif [[ "${GITHUB_REF}" == refs/tags/* ]]',
    './scripts/validate-release-metadata.sh "${tag}" "${release_commit}"',
    "GATED_TAG: ${{ steps.source.outputs.tag }}",
    "GATED_COMMIT: ${{ steps.source.outputs.commit }}",
    'tag="${GATED_TAG}"',
    'release_commit="${GATED_COMMIT}"',
    './scripts/validate-release-tag.sh "${tag}"',
    '''printf 'tag=%s\\ncommit=%s\\n' "${tag}" "${release_commit}" >> "${GITHUB_OUTPUT}"''',
    "id: release_assets",
    "release_id: ${{ steps.release_assets.outputs.release_id }}",
    "needs: publish",
    "runs-on: ubuntu-24.04",
    "RELEASE_ID: ${{ needs.publish.outputs.release_id }}",
    "RELEASE_ID: ${{ steps.parallel_assets.outputs.release_id }}",
]
for fragment in required_workflow_fragments:
    if fragment not in workflow:
        raise SystemExit(f"release workflow is missing contract fragment: {fragment}")

for forbidden in (
    'tag="$(< VERSION)"',
    'version="$(tr -d \'\\r\\n\' < VERSION)"',
    'release_commit="$(git rev-parse HEAD)"',
):
    if forbidden in workflow:
        raise SystemExit(
            f"release workflow still permits an untagged release-source fallback: {forbidden}"
        )

source_step = workflow[
    workflow.index("- name: Enforce release source"):
    workflow.index("- name: Cache Bazel artifacts")
]
if 'echo "tag=${tag}"' in source_step:
    raise SystemExit("release workflow writes the validated tag through an unsafe output form")

if '"${script_dir}/validate-release-tag.sh" "${tag}"' not in cut_release:
    raise SystemExit("cut-release does not use the canonical release tag validator")

remote_tag_check = cut_release.index('git ls-remote --exit-code --tags')
oci_occupancy_check = cut_release.index(
    '"${script_dir}/check-oci-chart-version-available.sh" "$version"'
)
first_release_mutation = cut_release.index("printf '%s\\n' \"$version\" > VERSION")
if not remote_tag_check < oci_occupancy_check < first_release_mutation:
    raise SystemExit(
        "cut-release must verify remote Git and OCI occupancy before changing metadata"
    )

chart_step_start = workflow.index("- name: Publish Helm chart to OCI registry")
chart_step_end = workflow.index("# Wasm plugins are published", chart_step_start)
chart_step = workflow[chart_step_start:chart_step_end]
for fragment in (
    "HARBOR_CHART_ROBOT_USERNAME",
    "HARBOR_CHART_ROBOT_SECRET",
    './scripts/validate-release-metadata.sh "${RELEASE_TAG}" "${RELEASE_COMMIT}"',
    './scripts/check-oci-chart-version-available.sh "${VERSION}"',
):
    if fragment not in chart_step:
        raise SystemExit(f"Helm publication is missing protected contract: {fragment}")
if "\n          OCI_USERNAME:" in chart_step or "\n          OCI_TOKEN:" in chart_step:
    raise SystemExit("Helm publication still consumes general image-publisher credentials")
if "run-helm.sh" not in chart_step:
    raise SystemExit("Helm publication does not use run-helm.sh")
if 'helm_runner}" package' not in chart_step or 'helm_runner}" push' not in chart_step:
    raise SystemExit("Helm publication must invoke the daemonless helm runner for package and push")
if not (
    chart_step.index("validate-release-metadata.sh")
    < chart_step.index("check-oci-chart-version-available.sh")
    < chart_step.index('helm_runner}" package')
    < chart_step.index('helm_runner}" push')
):
    raise SystemExit("Helm publication guards must run immediately before package and push")
if "already published; skipping OCI push" not in chart_step:
    raise SystemExit("Helm publication must skip an already-published chart on retry")

digest_check = '"${tag_check_script}" "${release_sha_tag}" "${RELEASE_TAG}" latest'
if workflow.count(digest_check) != 2:
    raise SystemExit("release workflow must run the same all-image digest check before and after publish")

checkout_step = workflow[
    workflow.index("- name: Checkout release commit"):
    workflow.index("- name: Derive managed agent release public key")
]
for fragment in (
    'cp scripts/sign-oci-publish.sh "${RUNNER_TEMP}/sign-oci-publish.sh"',
    'chmod +x "${RUNNER_TEMP}/sign-oci-publish.sh"',
    'cp scripts/install-download-integrity.sh "${RUNNER_TEMP}/install-download-integrity.sh"',
    'cp scripts/run-helm.sh "${RUNNER_TEMP}/run-helm.sh"',
    'cp scripts/oci_registry.sh "${RUNNER_TEMP}/oci_registry.sh"',
    'cp scripts/verify-oci-publish.sh "${RUNNER_TEMP}/verify-oci-publish.sh"',
    'cp scripts/cosign_common.sh "${RUNNER_TEMP}/cosign_common.sh"',
):
    if fragment not in checkout_step:
        raise SystemExit(f"release retry does not preserve the protected signer: {fragment}")

publish_images_step = workflow[
    workflow.index("- name: Publish container images"):
    workflow.index("- name: Publish Helm chart to OCI registry")
]
for fragment in (
    'SERVICERADAR_COSIGN_COMMON="${PWD}/scripts/cosign_common.sh"',
    'SERVICERADAR_REPO_ROOT="${PWD}"',
    'SERVICERADAR_SIGN_REGISTRY_TAG="${release_sha_tag}"',
    '"${sign_script}"',
    '"${verify_script}" "${verify_tags[@]}"',
):
    if fragment not in publish_images_step:
        raise SystemExit(f"release retry is missing registry-digest signing contract: {fragment}")
# Package publication provenance is exercised by //build/contracts:release_package_workflow_test.

if publish_images_step.count('SERVICERADAR_REPO_ROOT="${PWD}"') < 2:
    raise SystemExit("release retry must pass SERVICERADAR_REPO_ROOT to both sign and verify")
# Config-agnostic on purpose. This used to name `--config=remote_push`, a config that has
# since been deleted -- so the guard could never fire again and would have let a rebuild step
# back in under any other config. Match on the rebuild's shape instead.
if 'mapfile -t image_targets' in publish_images_step or '--stamp "${image_targets[@]}"' in publish_images_step:
    raise SystemExit("release retry must not rebuild image digests after registry equality is proven")

for fragment in (
    'source "${SERVICERADAR_COSIGN_COMMON:-${SCRIPT_DIR}/cosign_common.sh}"',
    'REPO_ROOT="${SERVICERADAR_REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"',
    'SIGN_REGISTRY_TAG="${SERVICERADAR_SIGN_REGISTRY_TAG:-}"',
    'oci_registry_digest',
    '"${repository}:${SIGN_REGISTRY_TAG}"',
    'digest_source="published registry tag ${repository}:${SIGN_REGISTRY_TAG}"',
    'digest_file="${IMAGE_METADATA_DIR}/${digest_target}.json.sha256"',
    'digest_source="Bazel OCI digest metadata ${digest_file}"',
):
    if fragment not in sign_oci_publish:
        raise SystemExit(f"OCI signer is missing canonical Bazel digest handling: {fragment}")
if '_index.json"' in sign_oci_publish:
    raise SystemExit("OCI signer still relies on non-top-level Bazel index metadata")

postflight = workflow.index("Rechecking release image digest equality after publish/build handling.")
signing = workflow.index("source ./scripts/ci/prepare-openbao-cosign-env.sh")
asset_verification = workflow.index("- name: Verify uploaded release assets via GitHub API")
finalizer_job = workflow.index("  finalize:")
parallel_asset_verification = workflow.index("- name: Wait for parallel release assets")
finalization = workflow.index("- name: Finalize GitHub release")
advance = workflow.index("- name: Advance demo release source branch")
if not (
    postflight
    < signing
    < asset_verification
    < finalizer_job
    < parallel_asset_verification
    < finalization
    < advance
):
    raise SystemExit(
        "release digest and complete asset verification must precede publication and demo advancement"
    )

dry_run_guard = "if: ${{ steps.release.outputs.dry_run != 'true' }}"
asset_verification_step = workflow[asset_verification:finalizer_job]
if dry_run_guard not in asset_verification_step:
    raise SystemExit("dry-run does not skip GitHub asset verification")
if "releases?per_page=100" not in asset_verification_step:
    raise SystemExit("release asset verification cannot discover a GitHub draft")

publish_job = workflow[workflow.index("  publish:"):finalizer_job]
finalize_job = workflow[finalizer_job:]
if "runs-on: serviceradar-signing" not in publish_job:
    raise SystemExit("release publication must remain on the signing runner")
if "runs-on: ubuntu-24.04" not in finalize_job or \
   "needs: [publish, image-security-dispatch]" not in finalize_job:
    raise SystemExit("release finalization must run after publication on a generic runner")
if "timeout-minutes: 95" not in finalize_job or "environment: release" not in finalize_job:
    raise SystemExit("release finalizer must have a bounded wait and release credentials")

finalizer_guard = (
    "if: ${{ needs.publish.outputs.dry_run != 'true' && "
    "needs.publish.outputs.draft != 'true' }}"
)
if finalizer_guard not in finalize_job:
    raise SystemExit("dry-run and requested-draft releases must skip parallel asset finalization")

parallel_asset_step = workflow[parallel_asset_verification:finalization]
native_upload_step = native_addons_workflow[
    native_addons_workflow.index("- name: Upload import index release asset"):
]
wasm_upload_step = wasm_plugins_workflow[
    wasm_plugins_workflow.index("- name: Upload import index release asset"):
]
source_security_upload_step = source_security_workflow[
    source_security_workflow.index("- name: Upload source security bundle to release"):
    source_security_workflow.index("- name: Summarize source security outputs")
]
image_security_upload_step = image_security_workflow[
    image_security_workflow.index("- name: Upload image security bundle to release"):
    image_security_workflow.index("- name: Summarize image security outputs")
]
required_parallel_assets = (
    ("serviceradar-native-addon-index.json", native_upload_step),
    ("serviceradar-wasm-plugin-index.json", wasm_upload_step),
    ("serviceradar-source-security.tar.gz", source_security_upload_step),
    ("serviceradar-image-security-${RELEASE_TAG}.tar.gz", image_security_upload_step),
)
for asset, publisher in required_parallel_assets:
    if asset not in parallel_asset_step:
        raise SystemExit(f"release finalizer does not require parallel asset: {asset}")
    if asset not in publisher:
        raise SystemExit(f"parallel publisher does not upload its required release asset: {asset}")
for fragment in (
    'PARALLEL_ASSET_WAIT_TIMEOUT_SECONDS: "5400"',
    'PARALLEL_ASSET_POLL_SECONDS: "10"',
    "--connect-timeout 5 --max-time 10",
    'response_draft="$(jq -r \'.draft // empty\' <<<"${response}")"',
    "Release ${RELEASE_TAG} remains a draft; refusing finalization and demo branch advancement.",
):
    if fragment not in parallel_asset_step:
        raise SystemExit(f"parallel release asset wait is missing fail-closed contract: {fragment}")

finalization_step = workflow[finalization:advance]
if "steps.parallel_assets.outputs.release_id" not in finalization_step:
    raise SystemExit("release finalization is not bound to the parallel-asset-verified release id")
advance_step = workflow[advance:]
if "steps.parallel_assets.outcome == 'success'" not in advance_step:
    raise SystemExit("demo advancement is not explicitly gated on parallel asset verification")
if "steps.finalize_release.outcome == 'success'" not in advance_step:
    raise SystemExit("demo advancement is not explicitly gated on release finalization")

for fragment in (
    "targetRevision: demo/prod-release",
    "automated:",
    "enabled: true",
    "prune: false",
    "selfHeal: false",
    "allowEmpty: false",
):
    if fragment not in demo_prod_application:
        raise SystemExit(f"demo release application is missing zero-touch contract: {fragment}")

sync_policy = demo_prod_application[demo_prod_application.index("  syncPolicy:"):]
if "prune: true" in sync_policy:
    raise SystemExit("zero-touch demo release automation must not enable pruning")
if "selfHeal: true" in sync_policy:
    raise SystemExit("zero-touch demo release automation must not overwrite live drift")

native_dispatch = native_addons_workflow[
    native_addons_workflow.index("  workflow_dispatch:"):
    native_addons_workflow.index("concurrency:")
]
for fragment in (
    "expected_commit:",
    'description: "Full reviewed commit SHA for the agent test artifact."',
    "required: true",
):
    if fragment not in native_dispatch:
        raise SystemExit(f"native add-on agent-test dispatch is missing: {fragment}")
for forbidden in ("mode:", "tag:", "sign_branch_catalog"):
    if forbidden in native_dispatch:
        raise SystemExit(f"native add-on dispatch still exposes production publishing control: {forbidden}")
if "  workflow_dispatch:" in wasm_plugins_workflow:
    raise SystemExit("Wasm production publisher still permits manual dispatch")
if "if: github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v')" not in native_addons_workflow:
    raise SystemExit("native production publisher is not restricted to v* tag pushes")
if "if: github.event_name == 'workflow_dispatch'" not in native_addons_workflow:
    raise SystemExit("native reviewed agent-test artifact dispatch was not preserved")

for worker_name, worker in (
    ("native add-on", native_addons_workflow),
    ("Wasm plugin", wasm_plugins_workflow),
):
    source_gate_start = worker.index("- name: Enforce release tag source")
    cache_start = worker.index("- name: Cache Bazel artifacts")
    upload_start = worker.index("- name: Upload import index release asset")
    if not source_gate_start < cache_start < upload_start:
        raise SystemExit(f"{worker_name} release source gate does not precede publication")
    source_gate = worker[source_gate_start:cache_start]
    for fragment in (
        'release_tag="${GITHUB_REF#refs/tags/}"',
        './scripts/validate-release-tag.sh "${release_tag}"',
        'expected_ref="refs/tags/${release_tag}"',
        'if [[ "${GITHUB_EVENT_NAME}" != "push" || "${GITHUB_REF}" != "${expected_ref}" ]]',
        'tag_commit="$(git rev-list -n1 "refs/tags/${release_tag}^{commit}")"',
        'checkout_commit="$(git rev-parse HEAD^{commit})"',
        '"${checkout_commit}" != "${tag_commit}"',
        'file_version="$(git show "${tag_commit}:VERSION")"',
        'if [[ "${release_tag}" != "v${file_version}" ]]',
        "git fetch --no-tags origin +refs/heads/staging:refs/remotes/origin/staging",
        'git merge-base --is-ancestor "${tag_commit}" "${RELEASE_BASE_REF}"',
    ):
        if fragment not in source_gate:
            raise SystemExit(f"{worker_name} release source gate is missing: {fragment}")

    for forbidden in (
        "github.event.inputs.tag",
        "Branch catalog dispatch",
        "workflow_dispatch recovery",
        "unset OPENBAO_SIGNING_ALLOWED_REFS_REGEX",
    ):
        if forbidden in worker:
            raise SystemExit(f"{worker_name} publisher retains unsafe dispatch behavior: {forbidden}")
    if "OPENBAO_SIGNING_ALLOWED_REFS_REGEX: '^refs/tags/v.*$'" not in worker and \
       "export OPENBAO_SIGNING_ALLOWED_REFS_REGEX='^refs/tags/v.*$'" not in worker:
        raise SystemExit(f"{worker_name} OpenBao signing is not restricted to release tags")

    for fragment in (
        "fetch_release()",
        '"${api_base}/releases?per_page=100" || true',
        'release_json="$(fetch_release)"',
        "https://api.github.com/repos/${GITHUB_REPOSITORY}",
        "select(type == \"object\") | .id // empty",
        'git rev-parse -q --verify "refs/tags/${release_tag}"',
        "Create release HTTP",
    ):
        if fragment not in worker:
            raise SystemExit(
                f"{worker_name} catalog publisher is not tolerant of concurrent draft creation: {fragment}"
            )

# The OpenBao token lives 20 minutes. Compile before the first login and log in
# again before each Transit phase; one login at the top of the step expired
# mid-signing after a cold bundle build (v1.4.95).
wasm_publish_step = wasm_plugins_workflow[
    wasm_plugins_workflow.index("- name: Publish Wasm plugin OCI artifacts"):
    wasm_plugins_workflow.index("- name: Generate import index")
]
openbao_login = "source ./scripts/ci/prepare-openbao-cosign-env.sh"
wasm_phases = [
    "./scripts/push_all_wasm_plugins.sh --build-only",
    openbao_login,
    './scripts/push_all_wasm_plugins.sh "${push_args[@]}"',
    openbao_login,
    "./scripts/sign-wasm-plugin-publish.sh",
    openbao_login,
    "./scripts/verify-wasm-plugin-publish.sh",
]
cursor = 0
for phase in wasm_phases:
    found = wasm_publish_step.find(phase, cursor)
    if found < 0:
        raise SystemExit(
            f"Wasm publish must build before OpenBao login and log in before each Transit phase: {phase}"
        )
    cursor = found + len(phase)

# The catalog step already holds the draft it created; re-resolving it by tag
# misses a draft the list API has not caught up with yet (v1.4.95).
if 'RELEASE_ID="${release_id}" ./scripts/upload-forgejo-release-asset.sh' not in native_upload_step:
    raise SystemExit("native add-on catalog upload does not bind to the release id it resolved")
if 'release_id="${RELEASE_ID:-}"' not in upload_release_asset:
    raise SystemExit("release asset upload helper ignores the caller's release id")

native_source_gate = native_addons_workflow[
    native_addons_workflow.index("- name: Enforce release tag source"):
    native_addons_workflow.index("- name: Cache Bazel artifacts")
]
wasm_source_gate = wasm_plugins_workflow[
    wasm_plugins_workflow.index("- name: Enforce release tag source"):
    wasm_plugins_workflow.index("- name: Cache Bazel artifacts")
]
if native_source_gate != wasm_source_gate:
    raise SystemExit("native add-on and Wasm release source gates have drifted")

for worker_name, worker in (
    ("source security", source_security_workflow),
    ("image security", image_security_workflow),
):
    if 'releases?per_page=100' not in worker:
        raise SystemExit(
            f"{worker_name} publisher cannot discover a draft release through the GitHub list API"
        )
if 'releases?per_page=100' not in upload_release_asset:
    raise SystemExit("release asset upload helper cannot resolve draft releases")
if '/releases/${1}' not in upload_release_asset:
    raise SystemExit("release asset upload helper does not fetch the full release before replacement")

repo_root = Path(sys.argv[1]).resolve().parents[2]
for worker_name, script_path in (
    ("native add-on", repo_root / "build/native_addons/publish_addon.sh"),
    ("Wasm plugin", repo_root / "build/wasm_plugins/publish_plugin.sh"),
):
    script = script_path.read_text()
    for fragment in (
        'if [[ -n "${extra_tag}" && "${tag}" == "${extra_tag}" ]]',
        "grep -Eiq 'immutable|already exists|precondition'",
        "already immutable; leaving the existing artifact.",
    ):
        if fragment not in script:
            raise SystemExit(
                f"{worker_name} publisher cannot recover an immutable Harbor extra tag: {fragment}"
            )
for worker_name, script_path in (
    ("native add-on", repo_root / "scripts/sign-native-addon-publish.sh"),
    ("Wasm plugin", repo_root / "scripts/sign-wasm-plugin-publish.sh"),
    ("OCI image", repo_root / "scripts/sign-oci-publish.sh"),
):
    script = script_path.read_text()
    if "legacy_signature_tag_exists" not in script:
        raise SystemExit(
            f"{worker_name} signer cannot skip an existing immutable cosign signature tag"
        )

install_skopeo = (repo_root / "scripts/install-skopeo.sh").read_text()
if "docker create" in install_skopeo or "docker cp" in install_skopeo:
    raise SystemExit("install-skopeo still requires a docker daemon")
if "export --platform" not in install_skopeo or "install_crane" not in install_skopeo:
    raise SystemExit("install-skopeo does not extract skopeo via crane")

run_helm = (repo_root / "scripts/run-helm.sh").read_text()
if "docker is required" in run_helm or "docker run" in run_helm:
    raise SystemExit("run-helm.sh still requires a docker daemon")
if "get.helm.sh" not in run_helm:
    raise SystemExit("run-helm.sh does not install a native helm binary")

for workflow_name, workflow_text in (
    ("release", workflow),
    ("native add-on", native_addons_workflow),
    ("Wasm plugin", wasm_plugins_workflow),
    ("image security", image_security_workflow),
):
    if "docker login" in workflow_text or "docker manifest inspect" in workflow_text:
        raise SystemExit(
            f"{workflow_name} publisher still talks to dockerd on ARC"
        )

ancestry_lines = [line for line in cut_release.splitlines() if "git merge-base --is-ancestor" in line]
if len(ancestry_lines) != 1:
    raise SystemExit("cut-release must print exactly one post-merge ancestry command")
if "&& git push $remote refs/tags/$tag:refs/tags/$tag" not in ancestry_lines[0] and \
   "&& git push origin refs/tags/$tag:refs/tags/$tag" not in ancestry_lines[0]:
    raise SystemExit("cut-release tag push is not mechanically chained to ancestry success")
PY


# RELEASE_PACKAGES must be the only set pulled into package_artifacts, and the
# prune script must stay wired into the release finalize job.
python3 - "${repo_root}" <<'PY2'
from pathlib import Path
import re
import sys

repo = Path(sys.argv[1])
packages_bzl = (repo / "build/packaging/packages.bzl").read_text()
release_targets = (repo / "build/packaging/release_targets.bzl").read_text()
release_workflow = (repo / ".github/workflows/release.yml").read_text()

if "RELEASE_PACKAGES" not in packages_bzl:
    raise SystemExit("packages.bzl must declare RELEASE_PACKAGES")
if "RELEASE_PACKAGES" not in release_targets:
    raise SystemExit("release_targets.bzl must consume RELEASE_PACKAGES")
if "sorted(PACKAGES.keys())" in release_targets:
    raise SystemExit("release_targets.bzl still ships every PACKAGES entry")
if "api.github.com" not in release_workflow:
    raise SystemExit("release workflow does not publish through the GitHub Releases API")

# Parse RELEASE_PACKAGES list roughly.
match = re.search(r"RELEASE_PACKAGES\s*=\s*\[(.*?)\]", packages_bzl, re.S)
if not match:
    raise SystemExit("unable to parse RELEASE_PACKAGES")
names = re.findall(r'"([^"]+)"', match.group(1))
required = {
    "agent",
    "nats",
    "cli",
    "log-collector",
    "flow-collector",
    "bmp-collector",
    "trapd",
    "rperf",
    "rperf-checker",
}
if set(names) != required:
    raise SystemExit(f"RELEASE_PACKAGES mismatch: got {sorted(names)}, want {sorted(required)}")
forbidden = {"core-elx", "web-ng", "agent-gateway", "datasvc", "faker", "bumblebee-scan"}
if forbidden & set(names):
    raise SystemExit(f"RELEASE_PACKAGES still includes control-plane packages: {sorted(forbidden & set(names))}")
print(f"RELEASE_PACKAGES ok: {', '.join(names)}")
PY2

sign_test_dir="${tmp_dir}/sign-oci-contract"
mkdir -p "${sign_test_dir}/bin" "${sign_test_dir}/docker/images" "${sign_test_dir}/bazel-bin/docker/images"

cat > "${sign_test_dir}/docker/images/image_inventory.bzl" <<'EOF'
PUBLISHABLE_IMAGES = [
    {"image": "first_img", "repository": "registry.example/serviceradar/first"},
    {"image": "second_img", "repository": "registry.example/serviceradar/second"},
    {"image": "third_img", "repository": "registry.example/serviceradar/third"},
]

EOF

printf 'sha256:%064d\n' 1 > "${sign_test_dir}/bazel-bin/docker/images/first_img.json.sha256"
printf 'sha256:%064d\n' 2 > "${sign_test_dir}/bazel-bin/docker/images/second_img.json.sha256"
printf 'sha256:%064d\n' 3 > "${sign_test_dir}/bazel-bin/docker/images/third_img.json.sha256"
printf 'test-public-key\n' > "${sign_test_dir}/cosign.pub"

cat > "${sign_test_dir}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"/service/token?"* ]]; then
  printf '{"token":"fake-token"}\n'
  exit 0
fi
if [[ "$*" == *"-w %{http_code}"* ]]; then
  printf '200'
  exit 0
fi
exit 0
EOF
chmod +x "${sign_test_dir}/bin/curl"

cat > "${sign_test_dir}/bin/jq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'fake-token\n'
EOF
chmod +x "${sign_test_dir}/bin/jq"

cat > "${sign_test_dir}/bin/cosign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_file="${FAKE_COSIGN_LOG:?}"
state_dir="${FAKE_COSIGN_STATE_DIR:?}"
printf '%s\n' "$*" >> "${log_file}"

cmd="${1:-}"
shift || true

case "${cmd}" in
  public-key)
    printf 'test-public-key\n'
    exit 0
    ;;
  triangulate)
    ref="${1:?}"
    repo="${ref%@*}"
    digest="${ref##*@}"
    printf '%s:%s.sig\n' "${repo}" "${digest/:/-}"
    exit 0
    ;;
  generate)
    printf '{"critical":{"type":"cosign container image signature"}}\n'
    exit 0
    ;;
  sign-blob)
    bundle_file=""
    sig_file=""
    while (($# > 0)); do
      case "$1" in
        --bundle)
          bundle_file="$2"
          shift 2
          ;;
        --output-signature)
          sig_file="$2"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    [[ -n "${sig_file}" ]] && printf 'ZmFrZS1zaWc=\n' > "${sig_file}"
    [[ -n "${bundle_file}" ]] && printf '{"base64Signature":"ZmFrZS1zaWc="}\n' > "${bundle_file}"
    exit 0
    ;;
  verify)
    has_key="false"
    ref="${!#}"
    while (($# > 0)); do
      case "$1" in
        --key)
          if [[ -n "${2:-}" && -f "${2}" ]]; then
            has_key="true"
          fi
          shift 2
          ;;
        --key=*)
          key_path="${1#--key=}"
          if [[ -n "${key_path}" && -f "${key_path}" ]]; then
            has_key="true"
          fi
          shift
          ;;
        *)
          shift
          ;;
      esac
    done
    if [[ "${has_key}" != "true" ]]; then
      echo "Error: cosign verify called without --key" >&2
      exit 1
    fi
    case "${FAKE_COSIGN_MODE:-}" in
      conflict_verified)
        exit 0
        ;;
      conflict_unverified_then_signed)
        if [[ -f "${state_dir}/signed-with-tlog" ]]; then
          exit 0
        fi
        echo "Error: no signatures found" >&2
        exit 1
        ;;
      conflict_never_verified)
        echo "Error: no signatures found" >&2
        exit 1
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  sign)
    if [[ "$*" == *"--tlog-upload=false"* || "$*" == *"--signing-config"* ]]; then
      echo "Error: unexpected unlogged cosign sign fallback: $*" >&2
      touch "${state_dir}/unlogged-sign-called"
      exit 1
    fi
    ref="${!#}"
    key="$(printf '%s' "${ref}" | tr '/:@' '___')"
    count_file="${state_dir}/count-${key}"
    count=0
    if [[ -f "${count_file}" ]]; then
      count="$(<"${count_file}")"
    fi
    count=$((count + 1))
    printf '%s\n' "${count}" > "${count_file}"

    case "${FAKE_COSIGN_MODE:-}" in
      conflict_verified)
        if [[ "${ref}" == *"/first@"* ]]; then
          echo "Error: signing [${ref}]: Rekor [POST /api/v1/log/entries][409] (entry already exists)" >&2
          exit 1
        fi
        exit 0
        ;;
      conflict_unverified_then_signed)
        if [[ "${ref}" == *"/first@"* && "${count}" -eq 1 ]]; then
          echo 'Error: signing ['"${ref}"']: [POST /api/v1/log/entries][409] createLogEntryConflict {"code":409,"message":"an equivalent entry already exists in the transparency log"}' >&2
          exit 1
        fi
        touch "${state_dir}/signed-with-tlog"
        exit 0
        ;;
      conflict_never_verified)
        echo "Error: signing [${ref}]: Rekor [POST /api/v1/log/entries][409] (entry already exists)" >&2
        exit 1
        ;;
      partial_failure_and_transient_retry)
        if [[ "${ref}" == *"/first@"* ]]; then
          echo "Error: signing [${ref}]: POST https://registry.example/v2/serviceradar/first/manifests: UNAUTHORIZED: authentication required" >&2
          exit 1
        fi
        if [[ "${ref}" == *"/second@"* && "${count}" -eq 1 ]]; then
          echo "Error: signing [${ref}]: Post \"https://rekor.example/api/v1/log/entries\": 503 Service Unavailable" >&2
          exit 1
        fi
        if [[ "${ref}" == *"/third@"* ]]; then
          echo "Error: signing [${ref}]: Post \"https://rekor.example/api/v1/log/entries\": 503 Service Unavailable" >&2
          exit 1
        fi
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  *)
    echo "unexpected fake cosign command: ${cmd}" >&2
    exit 2
    ;;
esac
EOF
chmod +x "${sign_test_dir}/bin/cosign"

run_fake_sign_oci() {
  local mode="$1"
  local log_file="$2"
  local state_dir="$3"
  mkdir -p "${state_dir}"
  : > "${log_file}"
  PATH="${sign_test_dir}/bin:${PATH}" \
    FAKE_COSIGN_MODE="${mode}" \
    FAKE_COSIGN_LOG="${log_file}" \
    FAKE_COSIGN_STATE_DIR="${state_dir}" \
    SERVICERADAR_REPO_ROOT="${sign_test_dir}" \
    BAZEL_BIN="${sign_test_dir}/bazel-bin" \
    OCI_REGISTRY="registry.example" \
    OCI_PROJECT="serviceradar" \
    COSIGN_KEY_REF="hashivault://cosign-release" \
    COSIGN_PUBLIC_KEY_FILE="${sign_test_dir}/cosign.pub" \
    COSIGN_SIGN_MAX_ATTEMPTS=3 \
    COSIGN_SIGN_RETRY_DELAY_SECONDS=0 \
    "${sign_oci_publish}"
}

# 1. Rekor 409 with valid existing signature verifies via cosign verify --key and succeeds without retrying sign.
run_fake_sign_oci "conflict_verified" "${sign_test_dir}/conflict-verified.log" "${sign_test_dir}/state-1"
if ! grep -q "^verify .*--key " "${sign_test_dir}/conflict-verified.log"; then
  echo "sign-oci-publish did not verify existing signature with cosign verify --key on Rekor 409" >&2
  exit 1
fi
if [[ "$(<"${sign_test_dir}/state-1/count-registry.example_serviceradar_first_sha256_0000000000000000000000000000000000000000000000000000000000000001")" -ne 1 ]]; then
  echo "sign-oci-publish retried cosign sign after cosign verify --key already succeeded" >&2
  exit 1
fi

# 2. Rekor 409 when registry has no signature yet retries full tlog signing instead of pushing an unlogged bundle.
run_fake_sign_oci "conflict_unverified_then_signed" "${sign_test_dir}/conflict-retry.log" "${sign_test_dir}/state-2"
if [[ -f "${sign_test_dir}/state-2/unlogged-sign-called" ]]; then
  echo "sign-oci-publish attempted an unlogged cosign sign after Rekor 409" >&2
  exit 1
fi
if [[ "$(<"${sign_test_dir}/state-2/count-registry.example_serviceradar_first_sha256_0000000000000000000000000000000000000000000000000000000000000001")" -ne 2 ]]; then
  echo "sign-oci-publish did not retry full signing when existing signature verification failed after Rekor 409" >&2
  exit 1
fi

# 3. Rekor 409 when cosign verify --key never succeeds must fail (never ignore the error).
if run_fake_sign_oci "conflict_never_verified" "${sign_test_dir}/conflict-unverified.log" "${sign_test_dir}/state-3" \
  >"${sign_test_dir}/conflict-unverified.out" 2>&1; then
  echo "sign-oci-publish ignored a Rekor 409 when cosign verify --key failed" >&2
  exit 1
fi

# 4. When one image fails, sign-oci-publish still signs remaining images, retries only transient errors, and lists all failed images at the end.
if run_fake_sign_oci "partial_failure_and_transient_retry" "${sign_test_dir}/partial.log" "${sign_test_dir}/state-4" \
  >"${sign_test_dir}/partial.out" 2>&1; then
  echo "sign-oci-publish succeeded despite image signing failures" >&2
  exit 1
fi
if [[ "$(<"${sign_test_dir}/state-4/count-registry.example_serviceradar_first_sha256_0000000000000000000000000000000000000000000000000000000000000001")" -ne 1 ]]; then
  echo "sign-oci-publish retried a permanent authentication failure" >&2
  exit 1
fi
if [[ "$(<"${sign_test_dir}/state-4/count-registry.example_serviceradar_second_sha256_0000000000000000000000000000000000000000000000000000000000000002")" -ne 2 ]]; then
  echo "sign-oci-publish did not retry a transient 503 failure on second image" >&2
  exit 1
fi
if [[ "$(<"${sign_test_dir}/state-4/count-registry.example_serviceradar_third_sha256_0000000000000000000000000000000000000000000000000000000000000003")" -ne 3 ]]; then
  echo "sign-oci-publish did not attempt third image after first image failed" >&2
  exit 1
fi
if ! grep -q "registry.example/serviceradar/first@sha256:" "${sign_test_dir}/partial.out" \
  || ! grep -q "registry.example/serviceradar/third@sha256:" "${sign_test_dir}/partial.out"; then
  echo "sign-oci-publish did not list every failed image at the end" >&2
  cat "${sign_test_dir}/partial.out" >&2
  exit 1
fi
if grep -q "  - registry.example/serviceradar/second@sha256:" "${sign_test_dir}/partial.out"; then
  echo "sign-oci-publish listed a recovered image as failed" >&2
  exit 1
fi

# 5. Exponential backoff schedule scales by 2^(attempt-1).
(
  source "${repo_root}/scripts/cosign_common.sh"
  [[ "$(cosign_retry_delay_seconds 5 1)" == "5" ]]
  [[ "$(cosign_retry_delay_seconds 5 2)" == "10" ]]
  [[ "$(cosign_retry_delay_seconds 5 3)" == "20" ]]
)

# 6. Rekor 409 on blob signing fails instead of producing an unlogged signature.
blob_test_dir="${tmp_dir}/sign-blob-conflict"
mkdir -p "${blob_test_dir}/bin"
cat > "${blob_test_dir}/bin/cosign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  sign-blob)
    if [[ "$*" == *"--tlog-upload=false"* || "$*" == *"--signing-config"* ]]; then
      touch "${FAKE_COSIGN_STATE_DIR}/unlogged-sign-blob-called"
      exit 0
    fi
    echo 'Error: signing blob: [POST /api/v1/log/entries][409] createLogEntryConflict {"code":409,"message":"an equivalent entry already exists in the transparency log"}' >&2
    exit 1
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "${blob_test_dir}/bin/cosign"
printf 'payload\n' > "${blob_test_dir}/payload"
if PATH="${blob_test_dir}/bin:${PATH}" \
  FAKE_COSIGN_STATE_DIR="${blob_test_dir}" \
  COSIGN_SIGN_MAX_ATTEMPTS=3 \
  COSIGN_SIGN_RETRY_DELAY_SECONDS=0 \
  bash -c '
    source "$1/scripts/cosign_common.sh"
    COSIGN_SIGN_ARGS=()
    cosign_sign_blob_to_files "$2/payload" "$2/bundle" "$2/sig" "$2/stdout" true
  ' _ "${repo_root}" "${blob_test_dir}" >"${blob_test_dir}/out" 2>&1; then
  echo "cosign_sign_blob_to_files reported success after a Rekor 409" >&2
  exit 1
fi
if [[ -f "${blob_test_dir}/unlogged-sign-blob-called" ]]; then
  echo "cosign_sign_blob_to_files fell back to an unlogged blob signature after a Rekor 409" >&2
  exit 1
fi

echo "release publish contracts verified"
