"""Static contract for selective web-stack OCI publication."""

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
WORKFLOW = ROOT / ".github/workflows/publish-oci.yml"
SELECTIVE_CONDITION = (
    "if: ${{ github.event.inputs.publish_scope == 'web-stack-commit-only' }}"
)
FULL_CONDITION = (
    "if: ${{ github.event.inputs.publish_scope != 'web-stack-commit-only' }}"
)


def workflow_step(source: str, name: str) -> str:
    marker = f"      - name: {name}\n"
    if marker not in source:
        return ""
    start = source.index(marker)
    end = source.find("\n      - name:", start + len(marker))
    return source[start:] if end == -1 else source[start:end]


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
        self.assertIn("GITHUB_STEP_SUMMARY", verify)
        self.assertNotIn("HARBOR_ROBOT_SECRET", verify)

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
