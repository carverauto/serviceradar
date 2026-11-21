"""Contracts for the CUDA media-worker build and publish workflow.

The workflow splits a credential-less native build from an in-cluster signing publish.
These tests hold that boundary, the digest pins, the signing order, and the image tool's
bundle verification and layer contents.
"""

import ast
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import unittest
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/publish-media-worker-cuda.yml"
IMAGE_TOOL = ROOT / "scripts/ci/media-worker-cuda-image.py"
BUILD_SCRIPT = ROOT / "scripts/build-media-worker-cuda.sh"
CUDA_BUILDER = "docker.io/nvidia/cuda@sha256:b7ae301dea2c162444795462ce17a05f6a516e5a75944b57af5b88540a1a2266"
COMMIT = "a" * 40
DIGEST = "sha256:" + "d" * 64
NOTICE_PACKAGES = ("libcublas-13-0", "libcurand-13-0", "cuda-nvrtc-13-0", "cuda-cudart-13-0")
LIBRARIES = ("libcublas.so.13", "libcublasLt.so.13", "libcurand.so.10",
             "libnvrtc.so.13", "libnvrtc-builtins.so.13.0", "libcudart.so.13")


def action(step):
    return step.get("uses", "").partition("@")[0]


def scalar_values(value):
    if isinstance(value, dict):
        for child in value.values():
            yield from scalar_values(child)
    elif isinstance(value, list):
        for child in value:
            yield from scalar_values(child)
    elif isinstance(value, str):
        yield value


def load_image_tool():
    spec = importlib.util.spec_from_file_location("media_worker_cuda_image", IMAGE_TOOL)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class MediaWorkerCudaWorkflowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = yaml.safe_load(WORKFLOW.read_text())
        cls.jobs = cls.workflow["jobs"]

    def test_build_jobs_hold_no_registry_signing_or_secret_access(self):
        self.assertEqual(self.workflow["permissions"], {"contents": "read"})
        self.assertEqual(set(self.jobs), {"preflight", "toolchain", "build", "publish"})
        for name, job in self.jobs.items():
            with self.subTest(job=name):
                permissions = job.get("permissions", self.workflow["permissions"])
                self.assertEqual(permissions, {} if name == "preflight" else {"contents": "read"})
                if name != "publish":
                    self.assertNotIn("environment", job)
                    for value in scalar_values([self.workflow.get("env"), job]):
                        for expression in re.findall(r"\$\{\{(.*?)\}\}", value, re.S):
                            self.assertNotRegex(expression.lower(), r"\bsecrets\b|\bgithub\s*(?:\.|\[)\s*['\"]?token")
                for step in job["steps"]:
                    if action(step) == "actions/checkout":
                        persist = step.get("with", {}).get("persist-credentials", True)
                        self.assertEqual(str(persist).lower(), "false")

    def test_build_runs_natively_in_the_digest_pinned_cuda_image(self):
        build = self.jobs["build"]
        self.assertEqual(build["runs-on"], "serviceradar-arm64-build")
        image = build["container"]["image"]
        self.assertEqual(image, CUDA_BUILDER)
        self.assertEqual(build["env"]["CUDA_BUILDER_IMAGE"], image)

    def test_every_action_is_pinned_to_a_commit(self):
        for name, job in self.jobs.items():
            for step in job["steps"]:
                if "uses" in step:
                    with self.subTest(job=name, step=step.get("name")):
                        self.assertRegex(step["uses"], r"^[\w.\-]+/[\w.\-]+@[0-9a-f]{40}$")

    def test_image_base_and_ca_bundle_are_the_bazel_pins(self):
        tool = load_image_tool()
        declarations = {}
        for node in ast.parse((ROOT / "MODULE.bazel").read_text()).body:
            if isinstance(node, ast.Expr) and isinstance(node.value, ast.Call):
                attrs = {kw.arg: kw.value for kw in node.value.keywords}
                name = attrs.get("name")
                if isinstance(name, ast.Constant) and name.value in {"ubuntu_noble", "mozilla_ca_bundle"}:
                    declarations[name.value] = {k: ast.literal_eval(v) for k, v in attrs.items()}
        base = declarations["ubuntu_noble"]
        self.assertEqual(tool.BASE_INDEX, base["image"].rsplit(":", 1)[0] + "@" + base["digest"])
        ca = declarations["mozilla_ca_bundle"]
        self.assertEqual((tool.CA_BUNDLE_SHA256, tool.CA_BUNDLE_URL), (ca["sha256"], ca["urls"][0]))

    def test_fetch_requests_the_workspace_rust_channel_for_arm64(self):
        with (ROOT / "rust-toolchain.toml").open("rb") as config:
            channel = tomllib.load(config)["toolchain"]["channel"]
        with tempfile.TemporaryDirectory() as work:
            curl = Path(work) / "curl"
            curl.write_text('#!/bin/bash\nprintf "%s\\n" "${@: -1}"\nexit 75\n')
            curl.chmod(0o755)
            result = subprocess.run(["bash", str(BUILD_SCRIPT), "fetch-toolchain", str(Path(work) / "archives")],
                                    env=os.environ | {"PATH": work + os.pathsep + os.environ["PATH"]},
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 75, result.stderr)
            self.assertEqual(result.stdout.strip(), f"https://static.rust-lang.org/dist/rustc-{channel}-aarch64-unknown-linux-gnu.tar.gz")

    def test_build_commands_preserve_nonempty_output_directories(self):
        for args in (["build", "toolchain"], ["fetch-toolchain"]):
            with self.subTest(args=args), tempfile.TemporaryDirectory() as work:
                sentinel = Path(work) / ".existing"
                sentinel.write_bytes(b"previous artifact")
                result = subprocess.run(["bash", str(BUILD_SCRIPT), *args, work],
                                        env=os.environ | {"GITHUB_SHA": COMMIT}, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("output directory must be empty", result.stderr)
                self.assertEqual(sentinel.read_bytes(), b"previous artifact")

    def test_downloads_follow_the_uploads_across_attempts(self):
        for producer, consumer in [("toolchain", "build"), ("build", "publish")]:
            job = self.jobs[producer]
            upload, = (s for s in job["steps"] if action(s) == "actions/upload-artifact")
            output, = (key for key, value in job["outputs"].items()
                       if value == "${{ steps." + upload["id"] + ".outputs.artifact-id }}")
            download, = (s["with"] for s in self.jobs[consumer]["steps"] if action(s) == "actions/download-artifact")
            self.assertEqual(download["artifact-ids"], "${{ needs." + producer + ".outputs." + output + " }}")
            self.assertNotIn("name", download)

    def test_dispatch_admission_controls_the_entire_privileged_job(self):
        triggers = self.workflow.get("on", self.workflow.get(True))
        self.assertEqual(set(triggers), {"workflow_dispatch"})
        preflight = self.jobs["preflight"]
        self.assertEqual(preflight["runs-on"], "ubuntu-24.04")
        self.assertEqual(self.jobs["toolchain"]["runs-on"], "ubuntu-24.04")
        publish = self.jobs["publish"]
        self.assertEqual(publish["runs-on"], "serviceradar-signing")
        self.assertEqual(publish["environment"], "release")
        self.assertEqual(set(publish["needs"]), {"preflight", "build"})
        condition = re.fullmatch(r"\$\{\{\s*needs\.preflight\.outputs\.(\w+)\s*==\s*'([^']*)'\s*\}\}", publish["if"])
        self.assertIsNotNone(condition, publish["if"])
        binding = preflight["outputs"][condition[1]]
        source = re.fullmatch(r"\$\{\{\s*steps\.(\w+)\.outputs\.(\w+)\s*\}\}", binding)
        self.assertIsNotNone(source, binding)
        step, = preflight["steps"]
        self.assertEqual(step["id"], source[1])
        self.assertNotIn("if", step)
        sign, = (s for s in publish["steps"] if "COSIGN_KEY_REF" in s.get("env", {}))
        signing_env = self.workflow["env"] | publish.get("env", {}) | sign["env"]
        existing = yaml.safe_load((ROOT / ".github/workflows/publish-oci.yml").read_text())
        rules = {s["env"]["OPENBAO_SIGNING_ALLOWED_REFS_REGEX"] for s in existing["jobs"]["publish"]["steps"]
                 if "OPENBAO_SIGNING_ALLOWED_REFS_REGEX" in s.get("env", {})}
        self.assertEqual(rules, {signing_env["OPENBAO_SIGNING_ALLOWED_REFS_REGEX"]})
        for ref, admitted in (
                ("refs/heads/staging", True), ("refs/heads/test/demo-test-0", True),
                ("refs/heads/test/demo-test-123", True), ("refs/heads/STAGING", False),
                ("refs/tags/staging", False), ("refs/heads/test/demo-test-", False),
                ("refs/heads/test/demo-test-x", False), ("refs/heads/test/demo-test-1x", False),
                ("refs/heads/test/demo-test-1/2", False), ("refs/tags/test/demo-test-12", False),
                ("refs/heads/feature", False)):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as work:
                output = Path(work) / "outputs"
                env = self.workflow["env"] | preflight.get("env", {}) | step.get("env", {})
                subprocess.run([step["shell"], "-ec", step["run"]], check=True,
                               env=env | {"GITHUB_REF": ref, "GITHUB_OUTPUT": str(output)})
                outputs = dict(line.split("=", 1) for line in output.read_text().splitlines())
                self.assertEqual(outputs[source[2]].lower() == condition[2].lower(), admitted)
        self.assertEqual(publish["concurrency"], {"group": "serviceradar-media-worker-cuda-${{ github.sha }}",
                                                  "cancel-in-progress": False})

    def test_excluded_dispatch_runs_only_unprivileged_build_operations(self):
        for manifest in ({"builder_image": CUDA_BUILDER}, {}, {"builder_image": "unknown"}):
            with self.subTest(manifest=manifest), tempfile.TemporaryDirectory() as work:
                self.check_build_manifest(Path(work), manifest)

    def check_build_manifest(self, root, manifest):
        scripts = root / "scripts"
        scripts.mkdir()
        builder = scripts / BUILD_SCRIPT.name
        builder.write_text('''#!/bin/bash
set -eu
echo "$1" >> commands
case "$1" in
    fetch-toolchain) ;;
    build)
        [[ "$CUDA_BUILDER_IMAGE" == "$EXPECTED_BUILDER" ]]
        mkdir -p "$3"
        printf '%s' "$BUILD_MANIFEST" > "$3/manifest.json"
        : > "$3/SHA256SUMS"
        ;;
    *) exit 1 ;;
esac
''')
        builder.chmod(0o755)
        for tool in ("mkdir", "awk", "sha256sum", "cat", "tr"):
            (root / tool).symlink_to(shutil.which(tool))
        env = self.workflow["env"] | {"PATH": str(root), "HOME": str(root), "RUNNER_TEMP": str(root),
                                      "BUILD_MANIFEST": json.dumps(manifest), "EXPECTED_BUILDER": CUDA_BUILDER,
                                      "GITHUB_REF": "refs/heads/test/demo-test-x", "GITHUB_SHA": COMMIT,
                                      "GITHUB_OUTPUT": str(root / "outputs"), "GITHUB_STEP_SUMMARY": str(root / "summary")}
        outputs = {}
        for name in ("toolchain", "build"):
            job = self.jobs[name]
            for step in job["steps"]:
                if "uses" in step:
                    self.assertIn(action(step), {"actions/checkout", "actions/upload-artifact", "actions/download-artifact"})
                    continue
                settings = env | job.get("env", {})
                for key, value in step.get("env", {}).items():
                    output = re.fullmatch(r"\$\{\{ fromJSON\(steps\.(\w+)\.outputs\.(\w+)\)\.(\w+) \}\}", value)
                    settings[key] = json.loads(outputs[output[1], output[2]]).get(output[3], "") if output else value
                output_file = root / "outputs"
                output_file.write_text("")
                result = subprocess.run(["/bin/bash", "-e", "-o", "pipefail", "-c", step["run"]],
                                        cwd=root, env=settings, text=True, capture_output=True)
                if result.returncode:
                    self.assertNotEqual(manifest.get("builder_image"), CUDA_BUILDER, result.stderr)
                    self.assertIn("incorrect manifest builder_image", result.stderr)
                    self.assertFalse(output_file.read_text())
                    return
                for line in output_file.read_text().splitlines():
                    key, value = line.split("=", 1)
                    outputs[step["id"], key] = value
        emitted = json.loads((root / "media-worker-cuda/manifest.json").read_bytes())
        self.assertEqual(emitted.get("builder_image"), CUDA_BUILDER)
        self.assertEqual((root / "commands").read_text().splitlines(), ["fetch-toolchain", "build"])

    def test_publish_verifies_each_digest_before_reporting_success(self):
        image = "serviceradar-media-worker-cuda"
        inventory = ast.parse((ROOT / "docker/images/image_inventory.bzl").read_text())
        native, = (ast.literal_eval(n.value) for n in inventory.body if isinstance(n, ast.Assign)
                   and any(isinstance(t, ast.Name) and t.id == "NATIVE_BUILD_IMAGES" for t in n.targets))
        self.assertIn(image, {entry["repository"] for entry in native})
        reference = f"registry.carverauto.dev/serviceradar/{image}:sha-{COMMIT}"
        expected = [
            "verify bundle", "setup", "push",
            "authenticate", f"build ./scripts/sign-oci-publish.sh {DIGEST}",
            f"build ./scripts/verify-oci-publish.sh {DIGEST}",
            f"promote --repositories {image} --tag sha-{COMMIT} --digest {DIGEST}",
            f"protected ./scripts/verify-oci-publish.sh {DIGEST}", "protected oras resolve " + reference,
        ]
        for fail in ("", expected[0], expected[5], expected[7]):
            with self.subTest(fail=fail), tempfile.TemporaryDirectory() as work:
                root = Path(work)
                scripts = root / "scripts"
                ci = scripts / "ci"
                ci.mkdir(parents=True)
                for tool in ("cosign", "oras", "crane"):
                    installer = scripts / f"install-{tool}.sh"
                    installer.write_text("#!/bin/bash\nexit 0\n")
                    installer.chmod(0o755)
                auth = ci / "prepare-openbao-cosign-env.sh"
                auth.write_text('echo authenticate >> calls\nexport VAULT_TOKEN=synthetic\n')
                calls = root / "calls"
                calls.touch()
                (ci / "media-worker-cuda-image.py").write_text(
                    "import os, sys\nassert sys.argv[1] == 'verify'\n"
                    "print('verify bundle', file=open('calls', 'a'))\n"
                    "sys.exit(int(os.environ['FAIL'] == 'verify bundle'))\n")
                harbor = ci / "harbor-publish.py"
                harbor.write_text(
                    "import os, sys\nfrom pathlib import Path\n"
                    "args = sys.argv[1:]\ncall = ' '.join(args)\n"
                    "if args[:2] == ['build', 'python3']:\n"
                    "    assert args[3] == 'push'\n    call = 'push'\n"
                    "    Path(args[args.index('--digest-file') + 1]).write_text(os.environ['BUILT'])\n"
                    "elif args[1:3] == ['oras', 'resolve']:\n"
                    "    print(os.environ['BUILT'])\n"
                    "elif len(args) > 1 and args[0] in ('build', 'protected'):\n"
                    "    assert os.environ['SERVICERADAR_NATIVE_IMAGE'] == 'serviceradar-media-worker-cuda'\n"
                    "    assert os.environ['VAULT_TOKEN'] == 'synthetic'\n"
                    "print(call, file=open('calls', 'a'))\nsys.exit(int(call == os.environ['FAIL']))\n")
                summary = root / "summary"
                output = root / "outputs"
                env = self.workflow["env"] | {
                    "PATH": os.environ["PATH"], "RUNNER_TEMP": work, "GITHUB_ENV": str(root / "env"),
                    "GITHUB_OUTPUT": str(output), "GITHUB_STEP_SUMMARY": str(summary),
                    "HARBOR_PUBLISH_TOOL": str(harbor), "GITHUB_SHA": COMMIT, "FAIL": fail, "BUILT": DIGEST,
                    "SUMS_SHA256": "c" * 64,
                }
                bindings = {"${{ env.IMAGE }}": env["IMAGE"]}
                for step in self.jobs["publish"]["steps"]:
                    if "run" not in step or "if" in step:
                        continue
                    settings = {k: bindings.get(v, v) for k, v in step.get("env", {}).items()}
                    if any(re.search(r"\bsecrets\.", value) for value in settings.values()):
                        self.assertIn("verify bundle", calls.read_text().splitlines())
                    output.write_text("")
                    result = subprocess.run(["bash", "-ec", step["run"]], cwd=root,
                                            env=env | settings, capture_output=True, text=True)
                    if result.returncode:
                        self.assertTrue(fail, result.stderr)
                        break
                    for line in output.read_text().splitlines():
                        key, value = line.split("=", 1)
                        bindings["${{ steps." + step["id"] + ".outputs." + key + " }}"] = value
                observed = calls.read_text().splitlines()
                self.assertEqual(observed, expected[:expected.index(fail) + 1] if fail else expected)
                if fail:
                    self.assertFalse(summary.exists())
                else:
                    self.assertIn(DIGEST, summary.read_text())


class MediaWorkerCudaBundleTest(unittest.TestCase):
    def setUp(self):
        self.tool = load_image_tool()
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.bundle = Path(self.directory.name) / "bundle"
        files = {"serviceradar-media-worker": b"synthetic-binary"}
        for library in LIBRARIES:
            files[f"lib/{library}"] = f"synthetic {library}".encode()
        for package in NOTICE_PACKAGES:
            files[f"third-party/{package}.copyright"] = f"synthetic notice for {package}".encode()
        binary_sha = hashlib.sha256(files["serviceradar-media-worker"]).hexdigest()
        files["manifest.json"] = json.dumps({"commit": COMMIT, "builder_image": CUDA_BUILDER, "cuda_compute_cap": "121",
                                             "binary": {"sha256": binary_sha}}).encode()
        for name, data in files.items():
            (self.bundle / name).parent.mkdir(parents=True, exist_ok=True)
            (self.bundle / name).write_bytes(data)
        self.sums_sha256 = self.write_sums()

    def write_sums(self):
        lines = [f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(self.bundle)}"
                 for p in sorted(self.bundle.rglob("*")) if p.is_file() and p.name != "SHA256SUMS"]
        (self.bundle / "SHA256SUMS").write_text("\n".join(lines) + "\n")
        return hashlib.sha256((self.bundle / "SHA256SUMS").read_bytes()).hexdigest()

    def test_verify_accepts_only_the_bundle_the_build_reported(self):
        listed = self.tool.verify(self.bundle, self.sums_sha256, COMMIT)
        self.assertIn("lib/libcublasLt.so.13", listed)

        with self.assertRaisesRegex(self.tool.BundleError, "digest the build job reported"):
            self.tool.verify(self.bundle, "0" * 64, COMMIT)

        tampered = self.bundle / "lib/libcudart.so.13"
        tampered.write_bytes(b"substituted")
        with self.assertRaisesRegex(self.tool.BundleError, "does not match SHA256SUMS"):
            self.tool.verify(self.bundle, self.sums_sha256, COMMIT)
        # Re-listing the substitute does not help: the build's digest no longer matches.
        self.write_sums()
        with self.assertRaisesRegex(self.tool.BundleError, "digest the build job reported"):
            self.tool.verify(self.bundle, self.sums_sha256, COMMIT)

    def test_build_and_bundle_require_the_approved_builder(self):
        manifest_path = self.bundle / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        for value in (None, "unknown", "docker.io/nvidia/cuda@sha256:" + "0" * 64):
            with self.subTest(builder=value):
                env = os.environ | {"GITHUB_SHA": COMMIT}
                if value is None:
                    env.pop("CUDA_BUILDER_IMAGE", None)
                    del manifest["builder_image"]
                else:
                    env["CUDA_BUILDER_IMAGE"] = manifest["builder_image"] = value
                result = subprocess.run(["bash", str(BUILD_SCRIPT), "build", "toolchain", str(self.bundle.parent / "out")],
                                        env=env, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("CUDA_BUILDER_IMAGE", result.stderr)
                manifest_path.write_text(json.dumps(manifest))
                with self.assertRaisesRegex(self.tool.BundleError, "builder_image"):
                    self.tool.verify(self.bundle, self.write_sums(), COMMIT)

    def test_verify_rejects_unlisted_unexpected_or_missing_files(self):
        cases = {
            "missing builtins": lambda: ((self.bundle / "lib/libnvrtc-builtins.so.13.0").unlink(), self.write_sums()),
            "duplicate builtins": lambda: (shutil.copyfile(self.bundle / "lib/libnvrtc-builtins.so.13.0",
                                                         self.bundle / "lib/libnvrtc-builtins.so.13.0.88"), self.write_sums()),
            "missing notice": lambda: ((self.bundle / "third-party/libcurand-13-0.copyright").unlink(), self.write_sums()),
            "extra notice": lambda: ((self.bundle / "third-party/random.txt").write_bytes(b"x"), self.write_sums()),
            "unlisted": lambda: (self.bundle / "lib/libextra.so.1").write_bytes(b"x"),
            "unexpected": lambda: ((self.bundle / "run.sh").write_bytes(b"x"), self.write_sums()),
            "missing": lambda: ((self.bundle / "lib/libcurand.so.10").unlink(), self.write_sums()),
        }
        for case, mutate in cases.items():
            with self.subTest(case=case):
                self.setUp()
                mutate()
                sums = hashlib.sha256((self.bundle / "SHA256SUMS").read_bytes()).hexdigest()
                with self.assertRaises(self.tool.BundleError):
                    self.tool.verify(self.bundle, sums, COMMIT)

    def test_layer_is_reproducible_and_runs_as_the_service_user(self):
        listed = self.tool.verify(self.bundle, self.sums_sha256, COMMIT)
        first, second = self.bundle.parent / "a.tar", self.bundle.parent / "b.tar"
        for out in (first, second):
            self.tool.write_layer(self.bundle, listed, b"synthetic CA bundle\n", out)
        self.assertEqual(first.read_bytes(), second.read_bytes())

        with tarfile.open(first) as layer:
            members = {member.name: member for member in layer.getmembers()}
            binary = members["usr/local/bin/serviceradar-media-worker"]
            self.assertEqual((binary.mode, binary.uid), (0o755, 0))
            for library in LIBRARIES:
                self.assertIn(f"usr/local/lib/serviceradar-cuda/{library}", members)
            builtins = [name for name in layer.getnames() if Path(name).name.startswith("libnvrtc-builtins.so.")]
            self.assertEqual(builtins, ["usr/local/lib/serviceradar-cuda/libnvrtc-builtins.so.13.0"])
            self.assertNotIn("usr/local/lib/serviceradar-cuda/libcuda.so.1", members)
            for package in NOTICE_PACKAGES:
                member = f"usr/share/doc/serviceradar-media-worker-cuda/third-party/{package}.copyright"
                self.assertEqual(layer.extractfile(member).read(), f"synthetic notice for {package}".encode())
            cache = members["var/cache/serviceradar-media-worker/cuda"]
            self.assertEqual((cache.isdir(), cache.uid), (True, 10001))
            passwd = layer.extractfile("etc/passwd").read().decode()
            self.assertIn("serviceradar:x:10001:10001:", passwd)
            self.assertEqual(layer.extractfile("etc/ssl/certs/ca-certificates.crt").read(),
                             b"synthetic CA bundle\n")
    def test_push_assembles_the_runtime_config_and_inspects_the_digest(self):
        repo = "registry.carverauto.dev/serviceradar-builds/serviceradar-media-worker-cuda"
        config = {}
        top_layer = None

        def registry(command, *args):
            nonlocal top_layer
            if command == "digest" and args[0] == "--platform":
                self.assertEqual(args[1:], ("linux/arm64", self.tool.BASE_INDEX))
                return "sha256:" + "b" * 64
            if command == "mutate":
                self.assertEqual(args[args.index("--tag") + 1], f"{repo}:sha-{COMMIT}")
                self.assertEqual(args[args.index("--entrypoint") + 1], "/usr/local/bin/serviceradar-media-worker")
                top_layer = hashlib.sha256(Path(args[args.index("--append") + 1]).read_bytes()).hexdigest()
                config["User"] = args[args.index("--user") + 1]
                for option, key in (("--env", "Env"), ("--label", "Labels")):
                    config[key] = dict(args[i + 1].split("=", 1) for i, arg in enumerate(args) if arg == option)
                return f"{repo}@{DIGEST}"
            self.assertEqual((command, *args), ("config", f"{repo}@{DIGEST}"))
            return json.dumps({"architecture": "arm64", "os": "linux", "config": config,
                               "rootfs": {"diff_ids": ["sha256:" + top_layer]}})

        with mock.patch.object(self.tool, "crane", registry), mock.patch.object(self.tool, "fetch_ca_bundle", return_value=b"CA"):
            self.assertEqual(self.tool.push(self.bundle, self.sums_sha256, COMMIT), DIGEST)
        self.assertEqual(config["User"], "10001:10001")
        self.assertEqual(config["Labels"]["org.opencontainers.image.revision"], COMMIT)
        self.assertEqual(config["Env"]["LD_LIBRARY_PATH"], "/usr/local/lib/serviceradar-cuda")
        self.assertNotIn("NVIDIA_VISIBLE_DEVICES", config["Env"])

    def test_push_refuses_another_commit_or_destination(self):
        with self.assertRaisesRegex(self.tool.BundleError, "manifest commit"):
            self.tool.push(self.bundle, self.sums_sha256, "b" * 40)
        for option, value in [("--tag", "registry.carverauto.dev/serviceradar/other:tag"), ("--revision", "b" * 40)]:
            result = subprocess.run([sys.executable, str(IMAGE_TOOL), "push", str(self.bundle), "--sums-sha256",
                                     self.sums_sha256, "--digest-file", str(self.bundle.parent / "digest"), option, value],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn("unrecognized arguments", result.stderr)


if __name__ == "__main__":
    unittest.main()
