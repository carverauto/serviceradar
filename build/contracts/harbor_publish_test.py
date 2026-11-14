"""Publisher process boundaries: credentials, repository routing and exit status."""

import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/ci/harbor-publish.py"


class HarborPublishTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.env = os.environ | {"HARBOR_LIFECYCLE_DIR": str(self.root),
                                 "SERVICERADAR_REPO_ROOT": str(self.root)}
        for role in ("build", "promotion"):
            path = self.root / role / "config.json"
            path.parent.mkdir()
            path.write_text(json.dumps({"auths": {"registry.carverauto.dev": {
                "auth": base64.b64encode(f"{role}:synthetic-password".encode()).decode()}}}))
        tool = self.root / "tool/k8s/harbor/promote-artifacts.py"
        tool.parent.mkdir(parents=True)
        tool.write_text("# synthetic capacity endpoint owner\n")
        inventory = self.root / "docker/images/image_inventory.bzl"
        inventory.parent.mkdir(parents=True)
        inventory.write_text('PUBLISHABLE_IMAGES = [{"image":"example_image",'
                             '"repository":"registry.carverauto.dev/serviceradar/example-worker"}]\n')

    def call(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), *args], env=self.env,
                              text=True, capture_output=True)

    def test_each_command_receives_only_its_scoped_registry_identity(self):
        for action, project, user in (("build", "serviceradar-builds", "build"),
                                      ("protected", "serviceradar", "promotion")):
            with self.subTest(action=action):
                result = self.call(action, sys.executable, "-c",
                                   'import json,os; print(json.dumps([os.environ["OCI_PROJECT"],'
                                   'os.environ["OCI_USERNAME"],os.environ["DOCKER_CONFIG"]]))')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), [project, user, str(self.root / user)])

    def test_child_failure_status_is_preserved_for_registry_preflight(self):
        result = self.call("build", sys.executable, "-c", "raise SystemExit(42)")
        self.assertEqual(result.returncode, 42)

    def test_bazel_upload_overrides_protected_inventory_with_build_repository(self):
        bazel = self.root / "bazel"
        bazel.write_text(f"#!{sys.executable}\nimport json,os,sys\n"
                         'print(json.dumps({"args":sys.argv[1:],"project":os.environ["OCI_PROJECT"]}))\n')
        bazel.chmod(0o755)
        self.env["PATH"] = str(self.root) + os.pathsep + self.env["PATH"]
        self.env["BAZEL_BUILD_FLAGS"] = "--config=example -c opt --stamp"
        result = self.call("push-images", "--only", "example-worker", "--tag", "sha-example")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            "args": ["run", "--config=example", "-c", "opt", "--stamp",
                     "//docker/images:example_image_push_commit_only", "--", "--repository",
                     "registry.carverauto.dev/serviceradar-builds/example-worker", "--tag", "sha-example"],
            "project": "serviceradar-builds"})

    def test_unknown_image_selection_refuses_publication(self):
        result = self.call("push-images", "--only", "not-in-inventory")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown image selection", result.stderr)


if __name__ == "__main__":
    unittest.main()
