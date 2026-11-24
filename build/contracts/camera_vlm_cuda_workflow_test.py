"""Contracts for the CUDA camera-vlm (crane-serve) build and publish workflow.

The workflow splits a credential-less native build from an in-cluster signing publish.
These tests hold that boundary, the digest pins, the signing order, and the image tool's
bundle verification and layer contents.
"""

import ast
import hashlib
import importlib.util
import io
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
WORKFLOW = ROOT / ".github/workflows/publish-camera-vlm-cuda.yml"
IMAGE_TOOL = ROOT / "scripts/ci/camera-vlm-cuda-image.py"
BUILD_SCRIPT = ROOT / "scripts/build-camera-vlm-cuda.sh"
CUDA_BUILDER = "docker.io/nvidia/cuda@sha256:b7ae301dea2c162444795462ce17a05f6a516e5a75944b57af5b88540a1a2266"
CRANE_COMMIT = "55835189af0848a180e6ed70313d59272e7c92a1"
COMMIT = "a" * 40
DIGEST = "sha256:" + "d" * 64
CHECKSUMS = hashlib.sha256(b"synthetic crane-serve").hexdigest() + "  crane-serve\n"
CHECKSUMS_SHA256 = hashlib.sha256(CHECKSUMS.encode()).hexdigest()
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


SECRET = "synthetic-credential/"
VAULT_TOKEN = SECRET + "VAULT_TOKEN"
CONTEXT_READ = re.compile(
    r"""\b(secrets|github|env)\b(?:\s*\.\s*([\w-]+)|\s*\[\s*['"]([^'"]+)['"]\s*\])?""", re.I)


def resolve_bindings(value, env, outputs):
    def expression(match):
        if match[0] in outputs:
            return outputs[match[0]]

        def read(selector):
            context, dotted, bracketed = selector.groups()
            key = dotted or bracketed
            if context.lower() == "secrets":
                return SECRET + (key or "VAULT_TOKEN").upper()
            values = env if context.lower() == "env" else {"token": SECRET + "GITHUB_TOKEN"}
            if key is None:
                return json.dumps(values)
            return next((v for k, v in values.items() if k.lower() == key.lower()), "")

        return CONTEXT_READ.sub(read, match[1].strip())

    return re.sub(r"\$\{\{(.*?)\}\}", expression, str(value), flags=re.S)


def effective_bindings(workflow, job, step, outputs=None, runner_env=None):
    env = {}
    outputs = outputs or {}
    for scope in (workflow.get("env", {}), job.get("env", {}), runner_env or {}, step.get("env", {})):
        env.update({k: resolve_bindings(v, env, outputs) for k, v in scope.items()})
    inputs = [resolve_bindings(v, env, outputs) for v in scalar_values(
        {k: v for k, v in step.items() if k != "env"})]
    return env, inputs


def load_image_tool():
    spec = importlib.util.spec_from_file_location("camera_vlm_cuda_image", IMAGE_TOOL)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CameraVlmCudaWorkflowTest(unittest.TestCase):
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
                    job_settings = {k: v for k, v in job.items() if k not in ("steps", "env")}
                    for step in [job_settings, *job["steps"]]:
                        env, inputs = effective_bindings(self.workflow, job, step)
                        self.assertFalse(any(SECRET in v for v in [*env.values(), *inputs]), step)
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
            cargo = Path(work) / "cargo"
            cargo.write_text("#!/bin/sh\nexit 0\n")
            cargo.chmod(0o755)
            result = subprocess.run(["bash", str(BUILD_SCRIPT), "fetch-inputs", str(Path(work) / "archives")],
                                    env=os.environ | {"PATH": work + os.pathsep + os.environ["PATH"]},
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 75, result.stderr)
            self.assertEqual(result.stdout.strip(), f"https://static.rust-lang.org/dist/rustc-{channel}-aarch64-unknown-linux-gnu.tar.gz")

    def test_build_commands_preserve_nonempty_output_directories(self):
        for args in (["build", "inputs"], ["fetch-inputs"]):
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
        self.assertEqual(publish["concurrency"], {"group": "serviceradar-camera-vlm-cuda-${{ github.sha }}",
                                                  "cancel-in-progress": False})
        inventory = ast.parse((ROOT / "docker/images/image_inventory.bzl").read_text())
        native, = (ast.literal_eval(n.value) for n in inventory.body if isinstance(n, ast.Assign)
                   and any(isinstance(t, ast.Name) and t.id == "NATIVE_BUILD_IMAGES" for t in n.targets))
        self.assertIn("serviceradar-camera-vlm-cuda", {entry["repository"] for entry in native})


class CameraVlmCudaBundleTest(unittest.TestCase):
    def setUp(self):
        self.tool = load_image_tool()
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.bundle = Path(self.directory.name) / "bundle"
        files = {"crane-serve": b"synthetic-crane-serve"}
        for library in LIBRARIES:
            files[f"lib/{library}"] = f"synthetic {library}".encode()
        for package in NOTICE_PACKAGES:
            files[f"third-party/{package}.copyright"] = f"synthetic notice for {package}".encode()
        files["third-party/crane.LICENSE"] = b"MIT License\n"
        binary_sha = hashlib.sha256(files["crane-serve"]).hexdigest()
        files["manifest.json"] = json.dumps({
            "commit": COMMIT,
            "crane_commit": CRANE_COMMIT,
            "builder_image": CUDA_BUILDER,
            "cuda_compute_cap": "121",
            "binary": {"sha256": binary_sha},
        }).encode()
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

    def test_verify_requires_pinned_crane_commit_and_license(self):
        manifest_path = self.bundle / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["crane_commit"] = "0" * 40
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(self.tool.BundleError, "crane_commit"):
            self.tool.verify(self.bundle, self.write_sums(), COMMIT)

        self.setUp()
        (self.bundle / "third-party/crane.LICENSE").unlink()
        with self.assertRaisesRegex(self.tool.BundleError, "crane.LICENSE"):
            self.tool.verify(self.bundle, self.write_sums(), COMMIT)

    def test_layer_is_reproducible_and_runs_as_the_service_user(self):
        listed = self.tool.verify(self.bundle, self.sums_sha256, COMMIT)
        first, second = self.bundle.parent / "a.tar", self.bundle.parent / "b.tar"
        for out, names, mtime in [(first, list(listed), 1_000_000), (second, list(reversed(listed)), 2_000_000)]:
            for name in names:
                os.utime(self.bundle / name, (mtime, mtime))
            self.tool.write_layer(self.bundle, names, b"synthetic CA bundle\n", out)
        self.assertEqual(first.read_bytes(), second.read_bytes())

        with tarfile.open(first) as layer:
            members = {member.name: member for member in layer.getmembers()}
            binary = members["usr/local/bin/crane-serve"]
            self.assertEqual((binary.mode, binary.uid), (0o755, 0))
            for library in LIBRARIES:
                self.assertIn(f"usr/local/lib/serviceradar-cuda/{library}", members)
            self.assertNotIn("usr/local/lib/serviceradar-cuda/libcuda.so.1", members)
            self.assertIn("usr/share/doc/serviceradar-camera-vlm-cuda/third-party/crane.LICENSE", members)
            cache = members["var/cache/serviceradar-camera-vlm/cuda"]
            self.assertEqual((cache.isdir(), cache.uid), (True, 10001))
            passwd = layer.extractfile("etc/passwd").read().decode()
            self.assertIn("serviceradar:x:10001:10001:", passwd)

    def test_push_assembles_the_runtime_config_and_inspects_the_digest(self):
        repo = "registry.carverauto.dev/serviceradar-builds/serviceradar-camera-vlm-cuda"
        config = {}
        top_layer = None
        arm64_digest = "sha256:" + "b" * 64

        def registry(command, *args):
            nonlocal top_layer
            if command == "digest" and args[0] == "--platform":
                self.assertEqual(args[1:], ("linux/arm64", self.tool.BASE_INDEX))
                return arm64_digest
            if command == "mutate":
                self.assertEqual(args[0], f"registry.carverauto.dev/mirror/library/ubuntu@{arm64_digest}")
                self.assertEqual(args[args.index("--tag") + 1], f"{repo}:sha-{COMMIT}")
                self.assertEqual(args[args.index("--entrypoint") + 1], "/usr/local/bin/crane-serve")
                self.assertEqual(args[args.index("--exposed-ports") + 1], "8080/tcp")
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
        self.assertEqual(config["Labels"]["io.serviceradar.crane.commit"], CRANE_COMMIT)
        self.assertEqual(config["Env"]["LD_LIBRARY_PATH"], "/usr/local/lib/serviceradar-cuda")
        self.assertEqual(config["Env"]["CUDA_CACHE_PATH"], "/var/cache/serviceradar-camera-vlm/cuda")
        self.assertNotIn("NVIDIA_VISIBLE_DEVICES", config["Env"])


if __name__ == "__main__":
    unittest.main()
