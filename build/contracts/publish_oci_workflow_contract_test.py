"""Contract tests for selective web-stack OCI publication."""

import os
import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]
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


def parsed_step(source: str, name: str) -> dict:
    return next(
        step
        for job in yaml.safe_load(source)["jobs"].values()
        for step in job["steps"]
        if step.get("name") == name
    )


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
            "Derive managed agent release public key",
            "Build (no publish)",
            "Verify managed agent release key stamp",
            "Publish images",
            "Summarize pushed tags",
        ):
            with self.subTest(step=name):
                self.assertIn(FULL_CONDITION, workflow_step(self.workflow, name))

    def run_selective_publish(self, ref="refs/heads/test/demo-test-7", fail=None, token=True):
        step = parsed_step(self.workflow, "Publish web stack commit images")
        sha = "1" * 40
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = Path(temp_dir)
            bin_dir = temp / "bin"
            bin_dir.mkdir()
            calls = temp / "calls"
            fakes = {
                # Records each publisher action with the signing state it saw.
                "python3": f"""
shift
printf '%s|%s|%s|%s\\n' "$*" "${{SERVICERADAR_SIGN_REGISTRY_TAG:-}}" \\
  "${{SERVICERADAR_OCI_REPOSITORIES:-}}" "${{VAULT_TOKEN:+vault}}" >> {calls}
case "$*" in
  "{fail or '-'}"*) exit 9 ;;
esac
""",
                "curl": "printf 'synthetic-login-response\\n'\n",
                "jq": "cat >/dev/null\nprintf 'synthetic\\n'\n",
            }
            for command, body in fakes.items():
                path = bin_dir / command
                path.write_text("#!/bin/bash\nset -euo pipefail\n" + body, encoding="utf-8")
                path.chmod(0o755)
            token_file = temp / "token"
            if token:
                token_file.write_text("synthetic-jwt", encoding="utf-8")
            env = {
                key: value
                for key, value in os.environ.items()
                if not key.startswith(("VAULT_", "COSIGN_", "OPENBAO_", "SERVICERADAR_", "BASH_FUNC_"))
                and key not in ("BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS")
            }
            env.update(step["env"])
            env.update({
                "PATH": f"{bin_dir}:{os.environ['PATH']}",
                "GITHUB_SHA": sha,
                "GITHUB_REF": ref,
                "HARBOR_PUBLISH_TOOL": "/synthetic/harbor-publish.py",
                "OPENBAO_K8S_TOKEN_FILE": str(token_file),
            })
            result = subprocess.run(
                ["/bin/bash", "-c", step["run"]],
                cwd=ROOT,
                check=False,
                capture_output=True,
                env=env,
                text=True,
            )
            recorded = calls.read_text(encoding="utf-8").splitlines() if calls.exists() else []
        return result, [tuple(line.split("|")) for line in recorded], sha

    def test_selective_mode_signs_and_verifies_before_promoting_commit_tags(self):
        result, calls, sha = self.run_selective_publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        tag = f"sha-{sha}"
        web_stack = "serviceradar-core-elx serviceradar-web-ng"
        self.assertEqual(
            calls,
            [
                (f"push-images --only {web_stack}", "", web_stack, ""),
                ("build ./scripts/sign-oci-publish.sh", tag, web_stack, "vault"),
                (f"build ./scripts/verify-oci-publish.sh {tag}", "", web_stack, "vault"),
                (f"promote --repositories {web_stack} --tag {tag}", "", web_stack, "vault"),
                (f"protected ./scripts/verify-oci-publish.sh {tag}", "", web_stack, "vault"),
            ],
        )
        for call in calls:
            self.assertNotIn("latest", call[0].split())

    def test_selective_mode_never_promotes_without_verified_signatures(self):
        for fail in (
            "build ./scripts/sign-oci-publish.sh",
            "build ./scripts/verify-oci-publish.sh",
        ):
            with self.subTest(fail=fail):
                result, calls, _sha = self.run_selective_publish(fail=fail)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse([call for call in calls if call[0].startswith("promote")])

        result, calls, _sha = self.run_selective_publish(token=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([call[0].split()[0] for call in calls], ["push-images"])

        result, calls, _sha = self.run_selective_publish(
            fail="protected ./scripts/verify-oci-publish.sh"
        )
        self.assertNotEqual(result.returncode, 0)

    def test_selective_verification_reads_the_protected_commit_images(self):
        job = yaml.safe_load(self.workflow)["jobs"]["publish"]
        step = next(s for s in job["steps"] if s.get("name") == "Verify web stack commit images")
        self.assertEqual(step["if"], SELECTIVE_CONDITION.removeprefix("if: "))
        sha = "1" * 40
        with tempfile.TemporaryDirectory() as temp_dir:
            lookups = Path(temp_dir) / "lookups"
            result, summary = run_workflow_step(
                self.workflow,
                "Verify web stack commit images",
                {"GITHUB_SHA": sha, "OCI_REGISTRY": job["env"]["OCI_REGISTRY"],
                 "OCI_PROJECT": job["env"]["OCI_PROJECT"], "LOOKUPS": str(lookups)},
                {"oras": 'printf "%s\\n" "$4" >> "${LOOKUPS}"\nprintf \'{"digest":"placeholder"}\\n\'\n',
                 "jq": f"printf '{VALID_DIGEST}\\n'\n"},
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            recorded = lookups.read_text(encoding="utf-8").splitlines()
        self.assertEqual(recorded, [
            f"registry.carverauto.dev/serviceradar/serviceradar-core-elx:sha-{sha}",
            f"registry.carverauto.dev/serviceradar/serviceradar-web-ng:sha-{sha}",
        ])
        self.assertEqual(summary.count(VALID_DIGEST), 2)

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
        for repository in ("serviceradar-core-elx", "serviceradar-web-ng"):
            self.assertIn(
                f"registry.example/serviceradar/{repository}:sha-{'1' * 40} -> {VALID_DIGEST}",
                summary,
            )

    def test_publish_signs_only_on_the_signing_branches(self):
        for name in ("Publish images", "Publish web stack commit images"):
            with self.subTest(step=name):
                self.assert_signing_branch_guard(parsed_step(self.workflow, name))

    def assert_signing_branch_guard(self, step):
        def guard(ref: str) -> subprocess.CompletedProcess[str]:
            with tempfile.TemporaryDirectory() as temp_dir:
                temp = Path(temp_dir)
                # Stand-in for the build-storage push that precedes signing.
                publisher = temp / "python3"
                publisher.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
                publisher.chmod(0o755)
                env = {
                    key: value
                    for key, value in os.environ.items()
                    if not key.startswith(("VAULT_", "COSIGN_", "OPENBAO_", "BASH_FUNC_"))
                    and key not in ("BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS")
                }
                env.update(step.get("env", {}))
                env.update({
                    "PATH": str(temp),
                    "GITHUB_SHA": "1" * 40,
                    "GITHUB_REF": ref,
                    "HARBOR_PUBLISH_TOOL": str(temp / "harbor-publish.py"),
                    "OPENBAO_K8S_TOKEN_FILE": str(temp / "missing-token"),
                })
                return subprocess.run(
                    ["/bin/bash", "-c", step["run"]],
                    cwd=ROOT,
                    check=False,
                    capture_output=True,
                    env=env,
                    text=True,
                )

        for ref in (
            "refs/heads/staging",
            "refs/heads/test/demo-test-7",
            "refs/heads/test/demo-test-27",
        ):
            with self.subTest(ref=ref):
                result = guard(ref)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("signing is not allowed", result.stderr)
                self.assertIn("No Kubernetes service account token", result.stderr)

        for ref in (
            "refs/heads/feature/demo-test-27",
            "refs/heads/test/demo-test-",
            "refs/heads/test/demo-test-27-extra",
            "refs/heads/xstaging",
            "refs/tags/v1.2.3",
        ):
            with self.subTest(ref=ref):
                result = guard(ref)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(
                    f"OpenBao signing is not allowed for ref '{ref}'.",
                    result.stderr,
                )

    def test_release_environment_uses_build_storage_credentials(self):
        job = yaml.safe_load(self.workflow)["jobs"]["publish"]
        self.assertEqual(job["environment"], "release")
        self.assertEqual(
            job["env"]["OCI_USERNAME"], "${{ secrets.HARBOR_BUILD_ROBOT_USERNAME }}"
        )
        self.assertEqual(
            job["env"]["OCI_TOKEN"], "${{ secrets.HARBOR_BUILD_ROBOT_SECRET }}"
        )

if __name__ == "__main__":
    unittest.main()
