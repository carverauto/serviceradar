"""Publisher process boundaries: credentials, repository routing and exit status."""

import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts/ci/harbor-publish.py"
SYNTHETIC_DIGEST = "sha256:" + "c" * 64


def pinned_jq():
    machine = platform.machine().lower()
    repository = {"x86_64": "jq_linux_amd64", "amd64": "jq_linux_amd64",
                  "aarch64": "jq_linux_arm64", "arm64": "jq_linux_arm64"}[machine]
    for dirpath, _dirnames, filenames in os.walk(os.environ["TEST_SRCDIR"], followlinks=True):
        if repository in dirpath and "downloaded" in filenames:
            return Path(dirpath) / "downloaded"
    raise FileNotFoundError("declared jq runfile is unavailable")


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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
                             '"repository":"registry.carverauto.dev/serviceradar/example-worker"}]\n\n')
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env["PATH"] = str(self.bin) + os.pathsep + self.env["PATH"]

    def fake(self, name, body):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\nimport json,os,pathlib,sys\n" + body)
        path.chmod(0o755)

    def call(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), *args], env=self.env,
                              text=True, capture_output=True)

    def test_retired_operator_entrypoints_refuse_before_tools_or_uploads(self):
        calls = self.root / "calls"
        for tool in ("bazel", "docker", "crane", "oras", "kubectl", "helm"):
            self.fake(tool, f"open({str(calls)!r}, 'a').write({tool!r})\n")
        commands = [["bash", str(REPO / script), *args] for script, args in (
            ("scripts/push_all_images.sh", []),
            ("scripts/build-images.sh", ["--push"]),
            ("build/buildbuddy/release_pipeline.sh", []))]
        commands += [["make", "-f", str(REPO / "Makefile"), target] for target in
                     ("push_all", "push-web-ng", "push_all_release", "push_wasm_plugins",
                      "demo-staging-web", "demo-staging-core")]
        for command in commands:
            with self.subTest(command=command):
                result = subprocess.run(command, cwd=self.root, env=self.env,
                                        text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertRegex(result.stderr, r"gh (workflow run publish-oci\.yml|run rerun) ")
                self.assertFalse(calls.exists(), result.stdout + result.stderr)

    def test_low_level_publishers_require_capacity_and_only_write_builds(self):
        events = self.root / "events"
        tool = self.root / "tool/k8s/harbor/promote-artifacts.py"
        tool.write_text("import os,sys\n"
                        f"open({str(events)!r}, 'a').write('capacity\\n')\n"
                        "assert sys.argv[1:] == ['--check-capacity-only']\n"
                        "sys.exit(int(os.environ.get('CAPACITY_EXIT', '0')))\n")
        self.fake("oras", f"open({str(events)!r}, 'a').write('upload ' + ' '.join(sys.argv[1:]) + '\\n')\n")
        self.fake("git", "print('a' * 40)\n")
        host_bin = self.root / ".local/bin"
        host_bin.mkdir(parents=True)
        (host_bin / "git").symlink_to(self.bin / "git")
        self.fake("signature", f"open({str(events)!r}, 'a').write('sign\\n')\n"
                  "pathlib.Path(sys.argv[sys.argv.index('--out') + 1]).write_text('{}')\n")
        bundle = self.root / "example.zip"
        bundle.write_bytes(b"synthetic bundle")
        metadata = self.root / "example.metadata.json"
        metadata.write_text(json.dumps({"addon_id": "example", "plugin_id": "example",
                                       "repository_name": "example", "artifact_type": "application/example",
                                       "bundle_media_type": "application/zip",
                                       "upload_signature_media_type": "application/example-signature"}))
        env = self.env | {"OCI_REGISTRY": "registry.example", "SERVICERADAR_AGENT_RELEASE_PRIVATE_KEY": "synthetic",
                          "HOME": str(self.root)}
        env.pop("OCI_PROJECT", None)
        for script, signing_flag in (("native_addons/publish_addon.sh", "--artifact-signature-tool"),
                                     ("wasm_plugins/publish_plugin.sh", "--upload-signature-tool")):
            command = ["bash", str(REPO / "build" / script), "--bundle", str(bundle),
                       "--metadata", str(metadata), "--oras", str(self.bin / "oras"),
                       signing_flag, str(self.bin / "signature")]
            with self.subTest(script=script):
                events.unlink(missing_ok=True)
                result = subprocess.run(command, cwd=self.root, env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                observed = events.read_text().splitlines()
                self.assertEqual(observed[0], "capacity")
                uploads = [event for event in observed if event.startswith("upload ")]
                self.assertEqual(len(uploads), 1)
                self.assertIn("registry.example/serviceradar-builds/example:sha-" + "a" * 40, uploads[0])
                for override in ({"CAPACITY_EXIT": "17"}, {"OCI_PROJECT": "serviceradar"},
                                 {"HARBOR_LIFECYCLE_DIR": str(self.root / "missing")}):
                    events.unlink()
                    result = subprocess.run(command, cwd=self.root, env=env | override,
                                            text=True, capture_output=True)
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    observed = events.read_text().splitlines() if events.exists() else []
                    self.assertEqual(observed, ["capacity"] if "CAPACITY_EXIT" in override else [])
                    events.touch()

    def test_signers_refuse_protected_writes_and_missing_capacity_tool(self):
        calls = self.root / "calls"
        for tool in ("cosign", "oras", "curl"):
            self.fake(tool, f"open({str(calls)!r}, 'a').write({tool!r})\n")
        for script in ("sign-oci-publish.sh", "sign-native-addon-publish.sh", "sign-wasm-plugin-publish.sh"):
            for override in ({"OCI_PROJECT": "serviceradar"},
                             {"OCI_PROJECT": "serviceradar-builds", "HARBOR_LIFECYCLE_DIR": str(self.root / "missing")}):
                with self.subTest(script=script, override=override):
                    result = subprocess.run(["bash", str(REPO / "scripts" / script)],
                                            env=self.env | override, text=True, capture_output=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(calls.exists(), result.stdout + result.stderr)
                    if override["OCI_PROJECT"] == "serviceradar":
                        self.assertIn("direct protected publication is forbidden", result.stderr)
                    else:
                        self.assertIn("promote-artifacts.py", result.stderr)

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
        self.fake("bazel", 'print(json.dumps({"args":sys.argv[1:],"project":os.environ["OCI_PROJECT"]}))\n')
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

    def test_release_digest_gate_reads_builds_and_post_promotion_verify_reads_protected(self):
        (self.bin / "jq").symlink_to(pinned_jq())
        lookups = self.root / "lookups"
        self.fake("oras", "assert sys.argv[1:4] == ['manifest', 'fetch', '--descriptor'], sys.argv\n"
                  f"open({str(lookups)!r}, 'a').write(sys.argv[4] + '\\n')\n"
                  f"print(json.dumps({{'digest': {SYNTHETIC_DIGEST!r}}}))\n")
        for action, project in (("build", "serviceradar-builds"), ("protected", "serviceradar")):
            with self.subTest(action=action):
                lookups.unlink(missing_ok=True)
                result = self.call(action, str(REPO / "scripts/check-oci-image-tags-exist.sh"),
                                   "sha-example", "v1.2.3", "latest")
                self.assertEqual(result.returncode, 0, result.stderr)
                base = f"registry.carverauto.dev/{project}/example-worker"
                self.assertEqual(lookups.read_text().splitlines(),
                                 [f"{base}:sha-example", f"{base}:v1.2.3", f"{base}:latest"])
                result = self.call(action, str(REPO / "scripts/verify-oci-publish.sh"), "--list-image-specs")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), [f"{base}|single"])

    def test_signing_and_verification_cover_only_the_selected_repositories(self):
        (self.bin / "jq").symlink_to(pinned_jq())
        inventory = self.root / "docker/images/image_inventory.bzl"
        inventory.write_text('PUBLISHABLE_IMAGES = [\n'
                             '  {"image":"worker","repository":"registry.carverauto.dev/serviceradar/example-worker"},\n'
                             '  {"image":"other","repository":"registry.carverauto.dev/serviceradar/example-other"},\n]\n\n')
        lookups = self.root / "lookups"
        self.fake("oras", f"open({str(lookups)!r}, 'a').write(sys.argv[-1] + '\\n')\nraise SystemExit(1)\n")
        for tool in ("cosign", "curl"):
            self.fake(tool, "raise SystemExit(1)\n")
        base = "registry.carverauto.dev/serviceradar-builds"
        self.env.update(SERVICERADAR_SIGN_REGISTRY_TAG="sha-example", COSIGN_KEY_REF="hashivault://example")
        for selection, specs in (("example-other", [f"{base}/example-other|single"]),
                                 ("", [f"{base}/example-worker|single", f"{base}/example-other|single"])):
            with self.subTest(selection=selection):
                self.env["SERVICERADAR_OCI_REPOSITORIES"] = selection
                result = self.call("build", str(REPO / "scripts/verify-oci-publish.sh"), "--list-image-specs")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), specs)
                lookups.unlink(missing_ok=True)
                result = self.call("build", str(REPO / "scripts/sign-oci-publish.sh"))
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(lookups.read_text().splitlines(),
                                 [spec.split("|")[0] + ":sha-example" for spec in specs])
        self.env["SERVICERADAR_OCI_REPOSITORIES"] = "example-other not-in-inventory"
        lookups.unlink()
        for script in ("verify-oci-publish.sh", "sign-oci-publish.sh"):
            with self.subTest(script=script):
                result = self.call("build", str(REPO / "scripts" / script), "--list-image-specs")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("not-in-inventory", result.stderr)
                self.assertFalse(lookups.exists())

    def setup_environment(self):
        runner = self.root / "runner"
        runner.mkdir()
        (self.root / "github-env").touch()
        return {"RUNNER_TEMP": str(runner), "GITHUB_ENV": str(self.root / "github-env"),
                "HARBOR_BUILD_ROBOT_USERNAME": "build", "HARBOR_BUILD_ROBOT_SECRET": "synthetic-build",
                "HARBOR_PROMOTION_ROBOT_USERNAME": "promotion",
                "HARBOR_PROMOTION_ROBOT_SECRET": "synthetic-promotion"}

    def test_failed_setup_removes_its_private_credentials(self):
        environment = self.setup_environment()
        self.env.update(environment)
        self.fake("oras", "raise SystemExit(3)\n")
        result = self.call("setup", "--chart")
        self.assertEqual(result.returncode, 3)
        self.assertEqual(list(Path(environment["RUNNER_TEMP"]).iterdir()), [])
        self.assertEqual(Path(environment["GITHUB_ENV"]).read_text(), "")

    def test_chart_services_from_setup_pin_only_images_in_an_older_release_inventory(self):
        inventory = self.root / "docker/images/image_inventory.bzl"
        inventory.write_text('PUBLISHABLE_IMAGES = [\n'
                             '  {"image":"worker","chart_service":"worker",'
                             '"repository":"registry.carverauto.dev/serviceradar/example-worker"},\n'
                             '  {"image":"added","chart_service":"addedLater",'
                             '"repository":"registry.carverauto.dev/serviceradar/example-added"},\n]\n\n')
        helper = self.root / "scripts/ci/publish-helm-bundle.py"
        helper.parent.mkdir(parents=True)
        helper.write_text("# synthetic chart helper\n")
        tool_source = b"import sys\n"
        self.fake("oras", "output = pathlib.Path(sys.argv[sys.argv.index('--output') + 1])\n"
                  "tool = output / 'k8s/harbor/promote-artifacts.py'\n"
                  "tool.parent.mkdir(parents=True)\ntool.write_text('import sys\\n')\n")
        yaml_source = self.root / "external/pyyaml"
        (yaml_source / "lib/yaml").mkdir(parents=True)
        (yaml_source / "lib/yaml/__init__.py").write_text("")
        self.fake("bazel", f"print({str(yaml_source)!r} + '/BUILD.bazel:1:1: py_library rule @pyyaml//:yaml')\n")
        environment = self.setup_environment()
        with mock.patch.dict(os.environ, self.env | environment):
            publisher = load("harbor_publish_setup", SCRIPT)
            publisher.TOOL_SHA = hashlib.sha256(tool_source).hexdigest()
            publisher.setup(include_chart=True)
            directory = Path(dict(line.split("=", 1) for line in
                                  Path(environment["GITHUB_ENV"]).read_text().splitlines())["HARBOR_LIFECYCLE_DIR"])
            inventory.write_text('PUBLISHABLE_IMAGES = [{"image":"worker",'
                                 '"repository":"registry.carverauto.dev/serviceradar/example-worker"}]\n')
            bundle = load("publish_helm_bundle_setup", REPO / "scripts/ci/publish-helm-bundle.py")
            reference = "registry.carverauto.dev/serviceradar/example-worker@" + SYNTHETIC_DIGEST
            receipt = {"artifacts": [{"reference": reference}],
                       "published": [{"repository": "example-worker", "digest": SYNTHETIC_DIGEST, "tags": ["v1.2.3"]}]}
            pins = bundle.image_pins(receipt, publisher.inventory("images"),
                                     json.loads((directory / "chart-services.json").read_text()), "v1.2.3")
        self.assertEqual(pins, {"worker": SYNTHETIC_DIGEST})


if __name__ == "__main__":
    unittest.main()
