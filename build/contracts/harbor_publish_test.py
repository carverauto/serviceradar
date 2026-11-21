"""Publisher process boundaries: credentials, repository routing and exit status."""

import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import yaml

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

    def test_bundle_publishers_give_the_commit_and_release_tags_one_digest(self):
        # Promotion refuses a release whose sha-<commit> and release tags name
        # different manifests. A real `oras push` stamps each manifest with its
        # own org.opencontainers.image.created time, so this registry gives every
        # push a fresh digest; only a single push carrying both tags agrees.
        registry = self.root / "registry.json"
        self.fake("oras", f"""
assert sys.argv[1] == "push", sys.argv
reference = next(arg for arg in sys.argv[2:] if arg.startswith("registry.example/"))
repository, tags = reference.rsplit(":", 1)
state = json.loads(pathlib.Path({str(registry)!r}).read_text())
digest = "sha256:%064x" % (len(state) + 1)
for tag in tags.split(","):
    state[repository + ":" + tag] = digest
pathlib.Path({str(registry)!r}).write_text(json.dumps(state))
""")
        self.fake("git", "print('a' * 40)\n")
        host_bin = self.root / ".local/bin"
        host_bin.mkdir(parents=True)
        for tool in ("git", "oras"):
            (host_bin / tool).symlink_to(self.bin / tool)
        self.fake("signature", "pathlib.Path(sys.argv[sys.argv.index('--out') + 1]).write_text('{}')\n")
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
            with self.subTest(script=script):
                registry.write_text("{}")
                result = subprocess.run(
                    ["bash", str(REPO / "build" / script), "--bundle", str(bundle), "--metadata", str(metadata),
                     "--oras", str(self.bin / "oras"), signing_flag, str(self.bin / "signature"),
                     "--tag", "v9.9.9"],
                    cwd=self.root, env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                state = json.loads(registry.read_text())
                repository = "registry.example/serviceradar-builds/example"
                self.assertEqual(sorted(state), [repository + ":sha-" + "a" * 40, repository + ":v9.9.9"])
                self.assertEqual(len(set(state.values())), 1, state)

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

    def test_each_promotion_preserves_its_receipt_before_the_next_promotion(self):
        self.fake("oras", "command = sys.argv[1:]\n"
                  f"if command[0] == 'resolve': print({SYNTHETIC_DIGEST!r})\n"
                  "elif command[0] == 'discover': print('{\"referrers\":[]}')\n"
                  "elif command[:2] == ['repo', 'tags']: print('{\"tags\":[]}')\n"
                  "elif command[0] != 'tag': raise SystemExit(9)\n")
        tool = self.root / "tool/k8s/harbor/promote-artifacts.py"
        tool.write_text("import json,sys\n"
                        "bundle = json.load(open(sys.argv[1]))\n"
                        "print(json.dumps({'artifacts': [{'reference': "
                        "'registry.carverauto.dev/serviceradar/' + a['repository'] + '@' + a['digest']} "
                        "for a in bundle['artifacts']]}))\n")
        expected = []
        for repository, tag in (("example-worker", "v1.2.3"), ("charts/serviceradar", "1.2.3")):
            result = self.call("promote", "--repositories", repository, "--tag", tag)
            self.assertEqual(result.returncode, 0, result.stderr)
            receipt = json.loads((self.root / "receipt.json").read_text())
            self.assertEqual(receipt["published"], [
                {"repository": repository, "digest": SYNTHETIC_DIGEST, "tags": [tag]}])
            expected.append(receipt)
        retained = list((self.root / "receipts").glob("*.json"))
        self.assertEqual(len(retained), 2)
        self.assertCountEqual([json.loads(path.read_text()) for path in retained], expected)
        for path in retained:
            self.assertNotIn("synthetic-password", path.read_text())
            self.assertNotIn("auths", path.read_text())

    def test_all_publishers_upload_only_receipts_before_unconditional_cleanup(self):
        for workflow in ("publish-oci", "release", "native-addons", "wasm-plugins", "external-wasm-plugin",
                         "publish-harbor-lifecycle-tools"):
            with self.subTest(workflow=workflow):
                model = yaml.safe_load((REPO / f".github/workflows/{workflow}.yml").read_text())
                jobs = [job for job in model["jobs"].values() if any(
                    step.get("name") == "Remove temporary Harbor publishing credentials"
                    for step in job.get("steps", []))]
                self.assertEqual(len(jobs), 1)
                steps = jobs[0]["steps"]
                uploads = [step for step in steps if step.get("name") == "Retain Harbor promotion receipts"]
                self.assertEqual(len(uploads), 1)
                upload = uploads[0]
                cleanup = next(step for step in steps if step.get("name") ==
                               "Remove temporary Harbor publishing credentials")
                self.assertLess(steps.index(upload), steps.index(cleanup))
                # Both steps run even if protected verification or the upload fails.
                for step in (upload, cleanup):
                    self.assertEqual(step["if"], "${{ always() && env.HARBOR_LIFECYCLE_DIR != '' }}")
                    self.assertFalse(step.get("continue-on-error", False))
                self.assertTrue(upload["uses"].startswith("actions/upload-artifact@"))
                self.assertEqual(upload["with"]["path"], "${{ env.HARBOR_LIFECYCLE_DIR }}/receipts/*.json")
                self.assertEqual(upload["with"]["if-no-files-found"], "error")
                self.assertEqual(upload["with"]["name"],
                                 "harbor-promotion-${{ github.workflow }}-${{ github.job }}-"
                                 "${{ github.run_id }}-${{ github.run_attempt }}")

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
        # A Dockerfile image is never published by a release, so the release gate ignores it.
        inventory = self.root / "docker/images/image_inventory.bzl"
        inventory.write_text(inventory.read_text() + 'DOCKERFILE_IMAGES = [\n'
                             '  {"repository":"example-runner","dockerfile":"Dockerfile","context":"."},\n]\n')
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

    def test_out_of_bazel_signing_binds_each_inventory_to_its_published_reference(self):
        (self.bin / "jq").symlink_to(pinned_jq())
        inventory = self.root / "docker/images/image_inventory.bzl"
        inventory.write_text('PUBLISHABLE_IMAGES = [\n'
                             '  {"image":"worker","repository":"registry.carverauto.dev/serviceradar/example-worker"},\n]\n\n'
                             'DOCKERFILE_IMAGES = [\n'
                             '  {"repository":"example-runner","dockerfile":"Dockerfile","context":"."},\n]\n\n'
                             'NATIVE_BUILD_IMAGES = [\n'
                             '  {"repository":"example-native"},\n]\n')
        lookups = self.root / "lookups"
        self.fake("oras", f"open({str(lookups)!r}, 'a').write(sys.argv[-1] + '\\n')\nraise SystemExit(1)\n")
        self.fake("cosign", f"open({str(lookups)!r}, 'a').write(sys.argv[-1] + '\\n') if sys.argv[1] == 'triangulate' else None\n"
                            "raise SystemExit(1)\n")
        self.fake("curl", "raise SystemExit(1)\n")
        self.env["COSIGN_KEY_REF"] = "hashivault://example"
        signer = str(REPO / "scripts/sign-oci-publish.sh")
        for variable, image, kind, other, args, suffix in (
                ("SERVICERADAR_DOCKERFILE_IMAGE", "example-runner", "Dockerfile", "example-native", [], ":v1.2.3"),
                ("SERVICERADAR_NATIVE_IMAGE", "example-native", "native-build", "example-runner",
                 [SYNTHETIC_DIGEST], "@" + SYNTHETIC_DIGEST)):
            with self.subTest(mode=variable):
                if not args:
                    self.env["SERVICERADAR_SIGN_REGISTRY_TAG"] = "v1.2.3"
                self.env[variable] = image
                result = self.call("build", signer, *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(lookups.read_text().splitlines(),
                                 [f"registry.carverauto.dev/serviceradar-builds/{image}{suffix}"])
                lookups.unlink()
                for candidate in ("example-worker", other, "not-declared"):
                    self.env[variable] = candidate
                    result = self.call("build", signer, *args)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(f"unknown {kind} image: {candidate}", result.stderr)
                    self.assertFalse(lookups.exists())
                self.env[variable] = image
                self.env.pop("SERVICERADAR_SIGN_REGISTRY_TAG", None)
                result = self.call("build", signer)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("verified digest" if args else "by its published tag", result.stderr)
                self.assertFalse(lookups.exists())
                del self.env[variable]

        self.env.update(SERVICERADAR_DOCKERFILE_IMAGE="example-runner",
                        SERVICERADAR_NATIVE_IMAGE="example-native",
                        SERVICERADAR_SIGN_REGISTRY_TAG="v1.2.3")
        result = self.call("build", str(REPO / "scripts/sign-oci-publish.sh"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not both", result.stderr)
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


class ImagePromotionTagsTest(unittest.TestCase):
    """Run `promote --kind images` against a fake two-project registry."""

    OLD = "sha256:" + "1" * 64
    NEW = "sha256:" + "2" * 64
    RELEASE = ["latest", "sha-example", "v1.2.3"]
    STATIC = "16.0-example1"

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        for role in ("build", "promotion"):
            path = self.root / role / "config.json"
            path.parent.mkdir()
            path.write_text(json.dumps({"auths": {"registry.carverauto.dev": {
                "auth": base64.b64encode(f"{role}:synthetic-password".encode()).decode()}}}))
        tool = self.root / "tool/k8s/harbor/promote-artifacts.py"
        tool.parent.mkdir(parents=True)
        tool.write_text("import json,os,sys\nbundle = json.load(open(sys.argv[1]))\n"
                        "json.dump(bundle, open(os.environ['BUNDLE_COPY'], 'w'))\n"
                        "print(json.dumps({'artifacts': [{'reference': 'registry.carverauto.dev/serviceradar/'"
                        " + a['repository'] + '@' + a['digest']} for a in bundle['artifacts']]}))\n")
        inventory = self.root / "docker/images/image_inventory.bzl"
        inventory.parent.mkdir(parents=True)
        inventory.write_text('PUBLISHABLE_IMAGES = [{"image":"example_db",'
                             '"repository":"registry.carverauto.dev/serviceradar/example-db",'
                             f'"static_tags":["{self.STATIC}"]}}]\n')
        self.state = self.root / "registry.json"
        self.tag_calls = self.root / "tag-calls"
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        oras = bin_dir / "oras"
        oras.write_text(f"#!{sys.executable}\nimport json,os,sys\n"
                        "state_path = os.environ['REGISTRY_STATE']\nstate = json.load(open(state_path))\n"
                        "def split(ref):\n"
                        "    repository, tag = ref.removeprefix('registry.carverauto.dev/').rsplit(':', 1)\n"
                        "    return repository.split('@')[0], tag\n"
                        "command = sys.argv[1:]\n"
                        "if command[0] == 'resolve':\n"
                        "    repository, tag = split(command[1])\n"
                        "    tags = state.get(repository, {})\n"
                        "    if tag not in tags: raise SystemExit(1)\n"
                        "    print(tags[tag])\n"
                        "elif command[0] == 'discover':\n"
                        "    # Build storage also holds a stale Sigstore bundle referrer.\n"
                        "    print(json.dumps({'referrers': [{'digest': 'sha256:' + '9' * 64,\n"
                        "        'artifactType': 'application/vnd.dev.sigstore.bundle.v0.3+json'}]}))\n"
                        "elif command[:2] == ['repo', 'tags']:\n"
                        "    repository = command[-1].removeprefix('registry.carverauto.dev/')\n"
                        "    print(json.dumps({'tags': sorted(state.get(repository, {}))}))\n"
                        "elif command[0] == 'tag':\n"
                        "    repository, digest = command[1].removeprefix('registry.carverauto.dev/').split('@')\n"
                        "    open(os.environ['TAG_CALLS'], 'a').write(json.dumps(command[2:]) + '\\n')\n"
                        "    for tag in command[2:]: state.setdefault(repository, {})[tag] = digest\n"
                        "    json.dump(state, open(state_path, 'w'))\n"
                        "else: raise SystemExit('unmodelled oras command')\n")
        oras.chmod(0o755)
        self.bundle = self.root / "bundle-copy.json"
        self.env = os.environ | {"HARBOR_LIFECYCLE_DIR": str(self.root), "SERVICERADAR_REPO_ROOT": str(self.root),
                                 "REGISTRY_STATE": str(self.state), "TAG_CALLS": str(self.tag_calls),
                                 "BUNDLE_COPY": str(self.bundle),
                                 "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"]}

    def promote(self, protected, *options):
        builds = {tag: self.NEW for tag in self.RELEASE + [self.STATIC]}
        # The build alias for this digest's classic signature exists too.
        builds[self.NEW.replace(":", "-") + ".sig"] = "sha256:" + "8" * 64
        self.state.write_text(json.dumps({"serviceradar-builds/example-db": builds,
                                          "serviceradar/example-db": protected}))
        arguments = [sys.executable, str(SCRIPT), "promote", "--kind", "images", *options]
        for tag in self.RELEASE:
            arguments += ["--tag", tag]
        result = subprocess.run(arguments, env=self.env, text=True, capture_output=True)
        registry = json.loads(self.state.read_text())["serviceradar/example-db"]
        receipt = self.root / "receipt.json"
        published = json.loads(receipt.read_text())["published"] if receipt.exists() else None
        return result, registry, published

    def test_bundle_requires_the_classic_signature_and_no_other_referrer(self):
        for options, signed in (((), True), (("--unsigned",), False)):
            with self.subTest(options=options):
                result, _, _ = self.promote({}, *options)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(self.bundle.read_text())["artifacts"], [
                    {"repository": "example-db", "digest": self.NEW, "required_referrers": [],
                     "legacy_signature": signed}])

    def test_explicit_digest_promotes_the_verified_build_when_the_source_tag_moves(self):
        tag = "sha-example"
        self.state.write_text(json.dumps({"serviceradar-builds/example-db": {tag: self.NEW}}))
        result = subprocess.run([sys.executable, str(SCRIPT), "promote", "--repositories", "example-db",
                                 "--tag", tag, "--digest", self.OLD], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.bundle.read_text())["artifacts"][0]["digest"], self.OLD)
        self.assertEqual(json.loads(self.state.read_text())["serviceradar/example-db"][tag], self.OLD)

    def test_existing_static_tag_with_another_image_is_kept_while_release_tags_publish(self):
        result, registry, published = self.promote({self.STATIC: self.OLD, "latest": self.OLD})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(registry, {self.STATIC: self.OLD, **{tag: self.NEW for tag in self.RELEASE}})
        self.assertEqual(published, [{"repository": "example-db", "digest": self.NEW, "tags": self.RELEASE}])

    def test_missing_static_tag_is_created_on_the_promoted_image(self):
        result, registry, published = self.promote({})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(registry, {tag: self.NEW for tag in self.RELEASE + [self.STATIC]})
        self.assertEqual(published[0]["tags"], self.RELEASE + [self.STATIC])

    def test_unchanged_static_tag_is_reported_without_being_rewritten(self):
        result, registry, published = self.promote({self.STATIC: self.NEW})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(registry, {tag: self.NEW for tag in self.RELEASE + [self.STATIC]})
        self.assertEqual(published[0]["tags"], self.RELEASE + [self.STATIC])
        self.assertEqual([json.loads(line) for line in self.tag_calls.read_text().splitlines()], [self.RELEASE])

    def test_conflicting_requested_fixed_tag_moves_no_tag(self):
        protected = {"v1.2.3": self.OLD}
        result, registry, published = self.promote(protected)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to replace fixed protected tag", result.stderr)
        self.assertEqual(registry, protected)
        self.assertFalse(self.tag_calls.exists())
        self.assertIsNone(published)


class ToolPublicationTest(unittest.TestCase):
    """Run the tool-publication workflow step against a fake two-project registry and OCI layout."""

    COMMIT = "1" * 40
    CREATED = "2026-01-01T00:00:00Z"
    STEP = "Publish and promote the promotion tool"

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        for role in ("build", "promotion"):
            path = self.root / role / "config.json"
            path.parent.mkdir()
            path.write_text(json.dumps({"auths": {"registry.carverauto.dev": {
                "auth": base64.b64encode(f"{role}:synthetic-password".encode()).decode()}}}))
        self.state = self.root / "registry.json"
        self.state.write_text(json.dumps({"layout": {}, "serviceradar-builds/harbor-lifecycle-tools": {},
                                          "serviceradar/harbor-lifecycle-tools": {}}))
        self.calls = self.root / "calls"
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        # A layout push yields a digest determined by the file and both annotations,
        # as an OCI manifest does; registry calls record which identity made them.
        oras = bin_dir / "oras"
        oras.write_text(f"#!{sys.executable}\nimport hashlib,json,os,pathlib,sys\n"
                        "state_path = os.environ['REGISTRY_STATE']\nstate = json.load(open(state_path))\n"
                        "role = pathlib.Path(os.environ.get('DOCKER_CONFIG', '/none')).name\n"
                        "command = sys.argv[1:]\n"
                        "open(os.environ['CALLS'], 'a').write(json.dumps([role] + command) + '\\n')\n"
                        "def save(): json.dump(state, open(state_path, 'w'))\n"
                        "def split(ref):\n"
                        "    repository, tag = ref.removeprefix('registry.carverauto.dev/').rsplit(':', 1)\n"
                        "    return repository, tag\n"
                        "if command[0] == 'push':\n"
                        "    annotations = [command[i + 1] for i, a in enumerate(command) if a == '--annotation']\n"
                        "    path = command[-1].split(':')[0]\n"
                        "    content = pathlib.Path(path).read_bytes()\n"
                        "    digest = 'sha256:' + hashlib.sha256(json.dumps([annotations, content.hex(), path]).encode()).hexdigest()\n"
                        "    state['layout'][command[command.index('--oci-layout') + 1]] = digest; save()\n"
                        "elif command[0] == 'resolve' and '--oci-layout' in command:\n"
                        "    print(state['layout'][command[-1]])\n"
                        "elif command[0] == 'resolve':\n"
                        "    repository, tag = split(command[1])\n"
                        "    if tag not in state[repository]: raise SystemExit(1)\n"
                        "    print(state[repository][tag])\n"
                        "elif command[:2] == ['repo', 'tags']:\n"
                        "    print(json.dumps({'tags': sorted(state[command[-1].removeprefix('registry.carverauto.dev/')])}))\n"
                        "elif command[0] == 'cp':\n"
                        "    repository, tag = split(command[-1])\n"
                        "    state[repository][tag] = state['layout'][command[command.index('--from-oci-layout') + 1]]; save()\n"
                        "elif command[0] == 'tag':\n"
                        "    repository, digest = command[1].removeprefix('registry.carverauto.dev/').split('@')\n"
                        "    for tag in command[2:]: state[repository][tag] = digest\n"
                        "    save()\n"
                        "    print('Tagging [registry] ' + command[1]); print('Tagged ' + ' '.join(command[2:]))\n"
                        "else: raise SystemExit('unmodelled oras command')\n")
        oras.chmod(0o755)
        # The published file is the promoter itself; this synthetic one records
        # that it ran with both identities and returns a verified receipt.
        self.source = ("import json,os,sys\n"
                       "bundle = json.load(open(sys.argv[1]))\n"
                       "assert sys.argv[2:] == ['--build-registry-config', os.environ['EXPECT_BUILD'],"
                       " '--promotion-registry-config', os.environ['EXPECT_PROMOTION']], sys.argv\n"
                       "open(os.environ['CALLS'], 'a').write(json.dumps(['promote', bundle]) + '\\n')\n"
                       "print(json.dumps({'version': 1, 'artifacts': [{'reference': "
                       "'registry.carverauto.dev/serviceradar/' + a['repository'] + '@' + a['digest']}"
                       " for a in bundle['artifacts']]}))\n").encode()
        self.workflow = (REPO / ".github/workflows/publish-harbor-lifecycle-tools.yml").read_text()
        self.env = os.environ | {
            "HARBOR_LIFECYCLE_DIR": str(self.root), "HARBOR_PUBLISH_TOOL": str(SCRIPT),
            "REGISTRY_STATE": str(self.state), "CALLS": str(self.calls), "RUNNER_TEMP": str(self.root),
            "GITHUB_STEP_SUMMARY": str(self.root / "summary.md"),
            "EXPECT_BUILD": str(self.root / "build/config.json"),
            "EXPECT_PROMOTION": str(self.root / "promotion/config.json"),
            "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"]}

    def run_step(self, **overrides):
        """Execute the workflow's own step body with its dispatch inputs."""
        step = next(step for job in yaml.safe_load(self.workflow)["jobs"].values()
                    for step in job["steps"] if step.get("name") == self.STEP)
        inputs = {"GITOPS_COMMIT": self.COMMIT, "TOOL_SHA256": hashlib.sha256(self.source).hexdigest(),
                  "TOOL_BASE64": base64.b64encode(self.source).decode(), "CREATED": self.CREATED,
                  "EXPECTED_DIGEST": ""} | overrides
        self.assertEqual(set(step["env"]), set(inputs))
        self.calls.unlink(missing_ok=True)
        return subprocess.run(["bash", "-c", step["run"]], env=self.env | inputs, text=True, capture_output=True)

    def registry(self):
        return json.loads(self.state.read_text())

    def recorded(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def writes(self):
        return [call for call in self.recorded() if call[0] == "promote" or call[1] in ("cp", "tag")]

    def test_first_publication_builds_promotes_with_itself_and_tags_the_commit(self):
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stderr)
        digest = self.registry()["serviceradar/harbor-lifecycle-tools"]["sha-" + self.COMMIT]
        reference = "registry.carverauto.dev/serviceradar/harbor-lifecycle-tools@" + digest
        # Real oras prints progress for `tag`; the summary holds only the reference.
        self.assertEqual([line for line in (self.root / "summary.md").read_text().splitlines()
                          if line.startswith("- `")], [f"- `{reference}`"])
        self.assertEqual(self.registry()["serviceradar-builds/harbor-lifecycle-tools"], {"sha-" + self.COMMIT: digest})
        # Build storage is written by the build identity, the tag by the promotion
        # identity, and promotion runs the published promoter on exactly this root.
        self.assertEqual([(call[0], call[1]) for call in self.writes()],
                         [("build", "cp"), ("promote", {"version": 1, "artifacts": [{
                             "repository": "harbor-lifecycle-tools", "digest": digest, "required_referrers": []}]}),
                          ("promotion", "tag")])
        receipts = list((self.root / "receipts").glob("*.json"))
        self.assertEqual(len(receipts), 1)
        self.assertEqual(json.loads(receipts[0].read_text())["published"],
                         [{"repository": "harbor-lifecycle-tools", "digest": digest, "tags": ["sha-" + self.COMMIT]}])
        # The same inputs reproduce the digest, so a re-run verifies and writes nothing.
        again = self.run_step(EXPECTED_DIGEST=digest)
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(self.writes(), [])
        # A different creation time is a different artifact.
        other = self.run_step(CREATED="2026-01-02T00:00:00Z", EXPECTED_DIGEST=digest)
        self.assertNotEqual(other.returncode, 0)
        self.assertIn("differs from expected", other.stderr)

    def test_mismatched_digest_source_or_existing_tag_writes_nothing(self):
        self.state.write_text(json.dumps({"layout": {}, "serviceradar-builds/harbor-lifecycle-tools": {},
                                          "serviceradar/harbor-lifecycle-tools": {
                                              "sha-" + "2" * 40: "sha256:" + "3" * 64}}))
        cases = [
            ({"EXPECTED_DIGEST": "sha256:" + "4" * 64}, "differs from expected"),
            ({"TOOL_SHA256": "0" * 64}, "reviewed SHA256"),
            ({"GITOPS_COMMIT": "2" * 40}, "refusing to replace fixed protected tag"),
            ({"GITOPS_COMMIT": "main"}, "40-character"),
        ]
        for overrides, message in cases:
            with self.subTest(overrides=overrides):
                result = self.run_step(**overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertEqual(self.writes(), [])
        self.assertEqual(self.registry()["serviceradar/harbor-lifecycle-tools"],
                         {"sha-" + "2" * 40: "sha256:" + "3" * 64})


class PublicationVerificationTest(unittest.TestCase):
    """The real verifier CLIs must require crypto verification, not just signature layers."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "jq").symlink_to(pinned_jq())
        scripts = self.root / "scripts"
        scripts.mkdir()
        # Use the actual declared scripts, isolated from any checkout's fallback public key.
        for name in ("verify-oci-publish.sh", "verify-native-addon-publish.sh", "verify-wasm-plugin-publish.sh",
                     "cosign_common.sh", "cosign_receipt.py", "oci_registry.sh", "wasm-plugin-publish-context.sh"):
            shutil.copy2(REPO / "scripts" / name, scripts / name)
        # The signer reused the digest's existing (receipt-less) signature in this run.
        self.ledger = self.root / "signing-ledger.jsonl"
        self.ledger.write_text(json.dumps({"event": "reused", "digest": "sha256:" + "a" * 64}) + "\n")
        # A reused receipt-less Wasm plugin or add-on signature must be on the frozen allowlist.
        sigstore = self.root / "docs/sigstore"
        sigstore.mkdir(parents=True)
        (sigstore / "pre-cutover-first-party-digests.json").write_text(json.dumps({"digests": ["sha256:" + "a" * 64]}))
        inventory = self.root / "docker/images/image_inventory.bzl"
        inventory.parent.mkdir(parents=True)
        inventory.write_text('PUBLISHABLE_IMAGES = [{"repository":"registry.example/serviceradar/example"}]\n\n'
                             'NATIVE_BUILD_IMAGES = [{"repository":"example"}]\n')
        metadata = self.root / "metadata"
        metadata.mkdir()
        (metadata / "example.metadata.json").write_text(json.dumps({
            "repository_name": "example", "artifact_type": "application/example",
            "bundle_media_type": "application/zip", "upload_signature_media_type": "application/example-signature",
            "artifacts": [{"tarball_file": "example.tar.gz"}]}))
        self.calls = self.root / "calls"
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("COSIGN_", "SIGSTORE_", "SERVICERADAR_"))}
        self.env.update(PATH=str(self.bin) + os.pathsep + self.env["PATH"], HOME=str(self.root),
                        COSIGN_KEY_REF="hashivault://example", OCI_REGISTRY="registry.example",
                        BAZEL_BIN_DIR=str(self.root), METADATA_DIR=str(metadata),
                        WASM_PLUGIN_METADATA_DIR=str(metadata),
                        WASM_PLUGIN_UPLOAD_SIGNATURE_TOOL=str(self.bin / "internal-signature"),
                        SERVICERADAR_SIGNING_LEDGER=str(self.ledger), CALL_LOG=str(self.calls))
        self.fake("internal-signature", "assert sys.argv[1] == 'verify'\n")
        self.fake("bazel", "if sys.argv[1] == 'cquery': print(pathlib.Path(__file__).parent / 'internal-signature')\n"
                  "elif sys.argv[1] != 'build': raise SystemExit(9)\n")
        self.fake("cosign", "with open(os.environ['CALL_LOG'], 'a') as log: log.write(sys.argv[1] + '\\n')\n"
                  "mode = os.environ['VERIFY_MODE']\n"
                  "if sys.argv[1] == 'triangulate': print('registry.example/serviceradar/example:sha256-' + 'a'*64 + '.sig')\n"
                  "elif sys.argv[1] == 'public-key':\n"
                  " if mode == 'key-unavailable': raise SystemExit(1)\n"
                  " print('synthetic public key')\n"
                  "elif sys.argv[1] == 'verify':\n"
                  " if mode == 'rejected': raise SystemExit(77)\n"
                  # Measured cosign v3.0.3 behaviour: by default it accepts a valid
                  # Sigstore bundle referrer even when the classic `.sig` does not
                  # verify; --new-bundle-format=false checks only the `.sig`, which
                  # is all admission reads.
                  " if mode == 'only-bundle-verifies' and '--new-bundle-format=false' in sys.argv:\n"
                  "  print('Error: no signatures found', file=sys.stderr); raise SystemExit(10)\n"
                  "else: raise SystemExit(9)\n")
        # Harbor lists the subject's classic `.sig` manifest as its referrer.
        self.fake("curl", "url = sys.argv[-1]\n"
                  "legacy = 'sha256:' + 'd'*64\n"
                  "if '/service/token?' in url: print('{\"token\":\"synthetic\"}')\n"
                  "elif '/referrers/' in url: print(json.dumps({'manifests': [{'digest': legacy, "
                  "'artifactType': 'application/vnd.oci.image.config.v1+json'}]}))\n"
                  "elif url.endswith('/manifests/' + legacy): print(json.dumps({'layers': [{"
                  "'mediaType': 'application/vnd.dev.cosign.simplesigning.v1+json', "
                  "'annotations': {'dev.cosignproject.cosign/signature': 'c3ludGhldGlj'}}]}))\n"
                  "elif '/manifests/sha256-' not in url: raise SystemExit(9)\n")
        self.fake("oras", "digest = 'sha256:' + 'a'*64\n"
                  "if sys.argv[1:3] == ['manifest', 'fetch']:\n"
                  " if '--descriptor' in sys.argv:\n"
                  "  if os.getenv('ADVANCE_TAG') and 'triangulate' in pathlib.Path(os.environ['CALL_LOG']).read_text().splitlines():\n"
                  "   digest = 'sha256:' + 'b'*64\n"
                  "  print(json.dumps({'digest': digest}))\n"
                  " else: print(json.dumps({'mediaType': 'application/vnd.oci.image.manifest.v1+json', "
                  "'artifactType': 'application/example', 'config': {'digest': digest}, 'layers': ["
                  "{'digest': digest, 'mediaType': media, 'annotations': {'org.opencontainers.image.title': title}} "
                  "for media,title in [('application/zip','example.zip'), ('application/example-signature','upload.json'), "
                  "('application/vnd.serviceradar.native-addon.artifact.v1+gzip','example.tar.gz'), "
                  "('application/vnd.serviceradar.native-addon.artifact-signature.v1+hex','example.tar.gz.sig')]]}))\n"
                  "elif sys.argv[1:3] == ['blob', 'fetch']:\n"
                  " dest = sys.argv[sys.argv.index('--output')+1]\n"
                  " if dest == '-': print('{\"config\":{}}')\n"
                  " else: pathlib.Path(dest).write_text('synthetic')\n"
                  "else: raise SystemExit(9)\n")

    def fake(self, name, body):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\nimport json,os,pathlib,sys\n" + body)
        path.chmod(0o755)

    def test_all_verifiers_fail_unless_the_classic_signature_verifies(self):
        cases = [("verify-oci-publish.sh", "sha256:" + "a" * 64, {"SERVICERADAR_NATIVE_IMAGE": "example"})]
        cases.extend((script, "sha-example", {}) for script in
                     ("verify-oci-publish.sh", "verify-native-addon-publish.sh", "verify-wasm-plugin-publish.sh"))
        for script, subject, selection in cases:
            for mode in ("key-unavailable", "rejected", "only-bundle-verifies", "valid"):
                with self.subTest(script=script, subject=subject, mode=mode):
                    self.calls.unlink(missing_ok=True)
                    result = subprocess.run(["bash", str(self.root / "scripts" / script), subject],
                                            env=self.env | selection | {"VERIFY_MODE": mode}, text=True, capture_output=True)
                    calls = self.calls.read_text().splitlines()
                    self.assertIn("public-key", calls, result.stderr)
                    if mode == "valid":
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertIn("verify", calls)
                    else:
                        self.assertNotEqual(result.returncode, 0, result.stdout)
                        if mode == "key-unavailable":
                            self.assertNotIn("verify", calls)
                            self.assertIn("Cosign verification identity", result.stderr)
                        else:
                            self.assertIn("verify", calls)

    def test_legacy_tag_advanced_before_final_verification_requires_its_own_ledger_entry(self):
        self.calls.touch()
        result = subprocess.run(["bash", str(self.root / "scripts/verify-oci-publish.sh"), "latest"],
                                env=self.env | {"ADVANCE_TAG": "1", "VERIFY_MODE": "valid"},
                                text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sha256:" + "b" * 64, result.stderr)
        self.assertIn("no signing-ledger record", result.stderr)

    def test_registry_config_returns_oras_blob_bytes_on_stdout(self):
        result = subprocess.run(["bash", "-c", 'source "$1"; oci_registry_config "$2"', "test",
                                 str(self.root / "scripts/oci_registry.sh"), "registry.example/serviceradar/example:latest"],
                                env=self.env, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b'{"config":{}}\n')

    def test_list_mode_reads_checkout_inventory_from_copied_verifier_without_cosign(self):
        copied = self.root / "runner-temp" / "bin" / "verify.sh"
        copied.parent.mkdir(parents=True)
        shutil.copy2(self.root / "scripts/verify-oci-publish.sh", copied)
        environment = self.env | {"VERIFY_MODE": "key-unavailable", "SERVICERADAR_REPO_ROOT": str(self.root),
                                  "SERVICERADAR_COSIGN_COMMON": str(self.root / "scripts/cosign_common.sh")}
        result = subprocess.run(["bash", str(copied), "--list-image-specs"],
                                env=environment, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "registry.example/serviceradar/example|single\n")
        self.assertFalse(self.calls.exists())

if __name__ == "__main__":
    unittest.main()
