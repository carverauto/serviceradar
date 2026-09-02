"""Contract tests for selective web-stack OCI publication."""

import os
import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
WORKFLOW = ROOT / ".github/workflows/publish-oci.yml"
SELECTIVE_CONDITION = (
    "if: ${{ github.event.inputs.publish_scope == 'web-stack-commit-only' }}"
)
FULL_CONDITION = (
    "if: ${{ github.event.inputs.publish_scope == 'full' }}"
)
VALID_DIGEST = "sha256:" + ("a" * 64)


def workflow_step(source: str, name: str) -> str:
    marker = f"      - name: {name}\n"
    if marker not in source:
        return ""
    start = source.index(marker)
    end = source.find("\n      - name:", start + len(marker))
    return source[start:] if end == -1 else source[start:end]


def workflow_run_script(source: str, name: str) -> str:
    step = workflow_step(source, name)
    marker = "        run: |\n"
    if marker not in step:
        return ""
    return textwrap.dedent(step.split(marker, 1)[1])


def run_workflow_step(
    source: str,
    name: str,
    env: dict[str, str] | None = None,
    fake_commands: dict[str, str] | None = None,
) -> tuple[subprocess.CompletedProcess[str], str]:
    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        bin_dir = temp / "bin"
        bin_dir.mkdir()
        for command, body in (fake_commands or {}).items():
            path = bin_dir / command
            path.write_text(
                "#!/usr/bin/env bash\nset -euo pipefail\n" + body,
                encoding="utf-8",
            )
            path.chmod(0o755)

        summary = temp / "summary.md"
        process_env = os.environ.copy()
        process_env.update(env or {})
        process_env["PATH"] = f"{bin_dir}:{process_env['PATH']}"
        process_env["GITHUB_STEP_SUMMARY"] = str(summary)
        result = subprocess.run(
            ["/bin/bash", "-c", workflow_run_script(source, name)],
            check=False,
            capture_output=True,
            env=process_env,
            text=True,
        )
        summary_text = summary.read_text(encoding="utf-8") if summary.exists() else ""
        return result, summary_text


class PublishOciWorkflowContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_dispatch_defaults_to_the_existing_full_publish(self):
        dispatch = self.workflow[
            self.workflow.index("  workflow_dispatch:") : self.workflow.index(
                "\nconcurrency:"
            )
        ]

        self.assertRegex(
            dispatch,
            re.compile(
                r"publish_scope:\n"
                r"(?:        .*\n)*?"
                r"        required: true\n"
                r"        default: full\n"
                r"        type: choice\n"
                r"        options:\n"
                r"          - full\n"
                r"          - web-stack-commit-only\n"
            ),
        )
        self.assertRegex(
            dispatch,
            re.compile(
                r"expected_commit:\n"
                r"(?:        .*\n)*?"
                r"        required: false\n"
                r"        type: string\n"
            ),
        )

    def test_publish_workflow_is_globally_serialized(self):
        concurrency = self.workflow[
            self.workflow.index("concurrency:") : self.workflow.index(
                "\npermissions:"
            )
        ]
        self.assertEqual(
            concurrency,
            "concurrency:\n"
            "  group: ${{ github.workflow }}\n"
            "  cancel-in-progress: false\n",
        )

    def test_publish_scope_allowlist_precedes_other_steps(self):
        scope_marker = "      - name: Validate publish scope\n"
        self.assertIn(scope_marker, self.workflow)
        self.assertLess(
            self.workflow.index("      - name: Checkout\n"),
            self.workflow.index(scope_marker),
        )
        self.assertLess(
            self.workflow.index(scope_marker),
            self.workflow.index("      - name: Validate selective publish commit\n"),
        )

    def test_publish_scope_allowlist_fails_closed(self):
        for scope in ("full", "web-stack-commit-only"):
            with self.subTest(scope=scope):
                result, _summary = run_workflow_step(
                    self.workflow,
                    "Validate publish scope",
                    {"PUBLISH_SCOPE": scope},
                )
                self.assertEqual(result.returncode, 0, result.stderr)

        for scope in ("", "FULL", "unexpected"):
            with self.subTest(scope=scope):
                result, _summary = run_workflow_step(
                    self.workflow,
                    "Validate publish scope",
                    {"PUBLISH_SCOPE": scope},
                )
                self.assertNotEqual(result.returncode, 0)

    def test_selective_publish_requires_the_exact_checked_out_commit(self):
        step = workflow_step(self.workflow, "Validate selective publish commit")

        self.assertIn(SELECTIVE_CONDITION, step)
        self.assertIn(
            "EXPECTED_COMMIT: ${{ github.event.inputs.expected_commit }}", step
        )
        self.assertIn('if [[ -z "${EXPECTED_COMMIT}" ]]; then', step)
        self.assertIn('actual_commit="$(git rev-parse HEAD)"', step)
        self.assertIn(
            'if [[ "${EXPECTED_COMMIT}" != "${actual_commit}" ]]; then',
            step,
        )
        self.assertIn(
            'if [[ "${EXPECTED_COMMIT}" != "${GITHUB_SHA}" ]]; then',
            step,
        )

    def test_full_publish_steps_are_skipped_in_selective_mode(self):
        for name in (
            "Setup Go",
            "Install Cosign",
            "Derive managed agent release public key",
            "Build (no publish)",
            "Verify managed agent release key stamp",
            "Publish images",
            "Summarize pushed tags",
        ):
            with self.subTest(step=name):
                self.assertIn(FULL_CONDITION, workflow_step(self.workflow, name))

    def test_selective_mode_pushes_and_verifies_only_commit_tags(self):
        publish = workflow_step(self.workflow, "Publish web stack commit images")
        verify = workflow_step(self.workflow, "Verify web stack commit images")

        self.assertIn(SELECTIVE_CONDITION, publish)
        self.assertEqual(
            re.findall(r"^          bazel run .+$", publish, re.MULTILINE),
            [
                "          bazel run -c opt --config=remote --stamp "
                "//docker/images:core_elx_image_amd64_push_commit_only",
                "          bazel run -c opt --config=remote --stamp "
                "//docker/images:web_ng_image_amd64_push_commit_only",
            ],
        )
        for forbidden in ("--tag", "//:images", "//:push", "cosign", "latest"):
            self.assertNotIn(forbidden, publish)

        self.assertIn(SELECTIVE_CONDITION, verify)
        self.assertIn('tag="sha-${GITHUB_SHA}"', verify)
        self.assertIn(
            'core_ref="${OCI_REGISTRY}/${OCI_PROJECT}/serviceradar-core-elx:${tag}"',
            verify,
        )
        self.assertIn(
            'web_ref="${OCI_REGISTRY}/${OCI_PROJECT}/serviceradar-web-ng:${tag}"',
            verify,
        )
        self.assertEqual(verify.count("oras manifest fetch --descriptor"), 1)
        self.assertIn(
            'if ! core_digest="$(resolve_digest "${core_ref}")"; then', verify
        )
        self.assertIn(
            'if ! web_digest="$(resolve_digest "${web_ref}")"; then', verify
        )
        self.assertIn("GITHUB_STEP_SUMMARY", verify)
        self.assertNotIn("HARBOR_ROBOT_SECRET", verify)

    def test_digest_verification_propagates_external_failures(self):
        fake_commands = {
            "oras": """
if [[ "${VERIFY_MODE:-success}" == "fetch-fail" ]]; then
  exit 23
fi
printf '{"digest":"placeholder"}\\n'
""",
            "jq": f"""
case "${{VERIFY_MODE:-success}}" in
  json-fail) exit 4 ;;
  empty-digest) true ;;
  invalid-digest) printf 'not-a-digest\\n' ;;
  *) printf '{VALID_DIGEST}\\n' ;;
esac
""",
        }
        common_env = {
            "GITHUB_SHA": "1" * 40,
            "OCI_PROJECT": "serviceradar",
            "OCI_REGISTRY": "registry.example",
        }

        for mode in ("fetch-fail", "json-fail", "empty-digest", "invalid-digest"):
            with self.subTest(mode=mode):
                result, summary = run_workflow_step(
                    self.workflow,
                    "Verify web stack commit images",
                    common_env | {"VERIFY_MODE": mode},
                    fake_commands,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(summary, "")

        result, summary = run_workflow_step(
            self.workflow,
            "Verify web stack commit images",
            common_env | {"VERIFY_MODE": "success"},
            fake_commands,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(summary.count(VALID_DIGEST), 2)

    def test_release_environment_uses_canonical_harbor_credentials(self):
        self.assertIn("    environment: release", self.workflow)
        self.assertIn(
            "      OCI_USERNAME: ${{ secrets.HARBOR_ROBOT_USERNAME }}",
            self.workflow,
        )
        self.assertIn(
            "      OCI_TOKEN: ${{ secrets.HARBOR_ROBOT_SECRET }}",
            self.workflow,
        )


if __name__ == "__main__":
    unittest.main()
