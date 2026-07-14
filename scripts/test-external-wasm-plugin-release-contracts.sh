#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${TEST_SRCDIR:-}" && -n "${TEST_WORKSPACE:-}" ]]; then
  repo_root="${TEST_SRCDIR}/${TEST_WORKSPACE}"
else
  repo_root="$(git rev-parse --show-toplevel)"
fi

workflow="${repo_root}/.forgejo/workflows/external-hpna-wasm-plugin.yml"

python3 - "${workflow}" <<'PY'
import sys
from pathlib import Path

workflow = Path(sys.argv[1]).read_text(encoding="utf-8")
required = [
    "workflow_dispatch:",
    "^refs/heads/(staging|main)$",
    "repository: carverauto/serviceradar-plugin-hpna",
    "persist-credentials: false",
    "git -C \"${plugin_root}\" merge-base --is-ancestor",
    "runs-on: serviceradar-signing",
    "environment: release",
    "enable-openid-connect: true",
    "OPENBAO_SIGNING_ALLOWED_REFS_REGEX: '^refs/heads/(staging|main)$'",
    "PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY: ${{ secrets.PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY }}",
    "--commit-sha \"${SOURCE_COMMIT}\"",
    "sign-wasm-plugin-publish.sh",
    "verify-wasm-plugin-publish.sh",
    "validate-external-wasm-plugin-bundle.py",
    "generate-wasm-plugin-import-index.sh",
    "publish-external-wasm-plugin-release.sh",
    "EXTERNAL_PLUGIN_FORGEJO_TOKEN: ${{ secrets.EXTERNAL_PLUGIN_FORGEJO_TOKEN }}",
]
for fragment in required:
    if fragment not in workflow:
        raise SystemExit(f"external plugin release workflow is missing: {fragment}")

build_job = workflow[workflow.index("  build:"):workflow.index("  publish:")]
publish_job = workflow[workflow.index("  publish:"):]
if "PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY" in build_job or "COSIGN_KEY_REF" in build_job:
    raise SystemExit("unprivileged external build job receives signing material")
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
