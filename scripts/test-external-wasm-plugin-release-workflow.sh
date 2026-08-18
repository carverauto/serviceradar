#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${TEST_SRCDIR:-}" && -n "${TEST_WORKSPACE:-}" ]]; then
  repo_root="${TEST_SRCDIR}/${TEST_WORKSPACE}"
else
  repo_root="$(git rev-parse --show-toplevel)"
fi

workflow="${repo_root}/.github/workflows/external-wasm-plugin.yml"

if ! command -v jq >/dev/null 2>&1 && [[ -n "${TEST_SRCDIR:-}" ]]; then
  case "$(uname -m)" in
    x86_64|amd64) jq_repository="jq_linux_amd64" ;;
    aarch64|arm64) jq_repository="jq_linux_arm64" ;;
    *) jq_repository="" ;;
  esac
  if [[ -n "${jq_repository}" ]]; then
    jq_binary="$(find -L "${TEST_SRCDIR}" -type f -path "*${jq_repository}/*" -perm -111 -print -quit)"
    if [[ -n "${jq_binary}" ]]; then
      mkdir -p "${TEST_TMPDIR}/jq-bin"
      ln -sf "${jq_binary}" "${TEST_TMPDIR}/jq-bin/jq"
      export PATH="${TEST_TMPDIR}/jq-bin:${PATH}"
    fi
  fi
fi

python3 - "${workflow}" <<'PY'
import sys
from pathlib import Path

workflow = Path(sys.argv[1]).read_text(encoding="utf-8")
required = [
    "workflow_dispatch:",
    "^refs/heads/(staging|main)$",
    "plugin_repository:",
    "^carverauto/serviceradar-plugin-[a-z0-9]",
    "repository: ${{ github.event.inputs.plugin_repository }}",
    "persist-credentials: false",
    "git -C \"${plugin_root}\" merge-base --is-ancestor",
    "runs-on: serviceradar-signing",
    "environment: release",
    "OPENBAO_SIGNING_ALLOWED_REFS_REGEX: '^refs/heads/(staging|main)$'",
    "PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY: ${{ secrets.PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY }}",
    "--commit-sha \"${SOURCE_COMMIT}\"",
    "sign-wasm-plugin-publish.sh",
    "verify-wasm-plugin-publish.sh",
    "validate-external-wasm-plugin-bundle.py",
    "generate-wasm-plugin-import-index.sh",
    "publish-external-wasm-plugin-release.sh",
    "for resource_dir in docs display schemas",
    "token: ${{ secrets.EXTERNAL_PLUGIN_GITHUB_READ_TOKEN || github.token }}",
    "EXTERNAL_PLUGIN_GITHUB_PUBLISH_TOKEN: ${{ secrets.EXTERNAL_PLUGIN_GITHUB_PUBLISH_TOKEN }}",
]
for fragment in required:
    if fragment not in workflow:
        raise SystemExit(f"external plugin release workflow is missing: {fragment}")

build_job = workflow[workflow.index("  build:"):workflow.index("  publish:")]
publish_job = workflow[workflow.index("  publish:"):]
if (
    "PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY" in build_job
    or "COSIGN_KEY_REF" in build_job
    or "EXTERNAL_PLUGIN_GITHUB_PUBLISH_TOKEN" in build_job
):
    raise SystemExit("unprivileged external build job receives signing material")
if "EXTERNAL_PLUGIN_GITHUB_READ_TOKEN" in publish_job:
    raise SystemExit("protected publisher receives the checkout-only token")
if "go test" in build_job or "make " in build_job or "/external-plugin/scripts/" in build_job:
    raise SystemExit("trusted build job executes code or scripts from the external repository")
if publish_job.index("verify-wasm-plugin-publish.sh") > publish_job.index(
    "publish-external-wasm-plugin-release.sh"
):
    raise SystemExit("external release is published before signature verification")
PY

bash -n \
  "${repo_root}/scripts/install-external-wasm-tinygo.sh" \
  "${repo_root}/scripts/publish-external-wasm-plugin-release.sh"
python3 "${repo_root}/scripts/test-publish-external-wasm-plugin-release.py"
python3 "${repo_root}/scripts/test-validate-external-wasm-plugin-bundle.py"

echo "external Wasm plugin protected release contracts verified"
