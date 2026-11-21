"""Contracts for the CUDA media-worker build and publish workflow.

The workflow splits a credential-less native build from an in-cluster signing publish.
These tests hold that boundary, the digest pins, the signing order, and the image tool's
bundle verification and layer contents.
"""

import hashlib
import importlib.util
import json
from pathlib import Path
import re
import tarfile
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/publish-media-worker-cuda.yml"
IMAGE_TOOL = ROOT / "scripts/ci/media-worker-cuda-image.py"
BUILD_SCRIPT = ROOT / "scripts/build-media-worker-cuda.sh"
DIGEST_REF = re.compile(r"^[a-z0-9.\-/]+@sha256:[0-9a-f]{64}$")
CREDENTIAL_MARKERS = ("secrets.", "OPENBAO", "COSIGN", "HARBOR", "VAULT", "SIGSTORE", "id-token")


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
        for name in ("toolchain", "build"):
            with self.subTest(job=name):
                job = self.jobs[name]
                self.assertEqual(job["permissions"], {"contents": "read"})
                self.assertNotIn("environment", job)
                text = yaml.safe_dump(job)
                for marker in CREDENTIAL_MARKERS:
                    self.assertNotIn(marker, text)
                for step in job["steps"]:
                    self.assertFalse(step.get("with", {}).get("persist-credentials", False))

    def test_build_runs_natively_in_the_digest_pinned_cuda_image(self):
        build = self.jobs["build"]
        self.assertEqual(build["runs-on"], "serviceradar-arm64-build")
        image = build["container"]["image"]
        self.assertRegex(image, DIGEST_REF)
        self.assertEqual(build["env"]["CUDA_BUILDER_IMAGE"], image)

    def test_every_action_is_pinned_to_a_commit(self):
        for name, job in self.jobs.items():
            for step in job["steps"]:
                if "uses" in step:
                    with self.subTest(job=name, step=step.get("name")):
                        self.assertRegex(step["uses"], r"^[\w.\-]+/[\w.\-]+@[0-9a-f]{40}$")

    def test_image_base_and_ca_bundle_are_the_bazel_pins(self):
        tool = load_image_tool()
        module = (ROOT / "MODULE.bazel").read_text()
        ubuntu = re.search(r'name = "ubuntu_noble",\s*digest = "(sha256:[0-9a-f]{64})",\s*image = "([^"]+):', module)
        self.assertEqual(tool.BASE_INDEX, f"{ubuntu[2]}@{ubuntu[1]}")
        ca = re.search(r'name = "mozilla_ca_bundle",[\s\S]*?sha256 = "([0-9a-f]{64})",\s*urls = \[\s*"([^"]+)"', module)
        self.assertEqual((tool.CA_BUNDLE_SHA256, tool.CA_BUNDLE_URL), (ca[1], ca[2]))

    def test_rust_pin_matches_the_repository_toolchain(self):
        channel = re.search(r'^channel = "([^"]+)"', (ROOT / "rust-toolchain.toml").read_text(), re.M)[1]
        pinned = re.search(r'^RUST_VERSION="([^"]+)"', BUILD_SCRIPT.read_text(), re.M)[1]
        self.assertEqual(pinned, channel)

    def test_publish_runs_only_on_signing_refs_and_signs_before_reporting_success(self):
        publish = self.jobs["publish"]
        self.assertEqual(publish["runs-on"], "serviceradar-signing")
        self.assertEqual(publish["needs"], "build")
        self.assertIn("refs/heads/staging", publish["if"])
        self.assertIn("refs/heads/test/demo-test-", publish["if"])

        publish_oci = yaml.safe_load((ROOT / ".github/workflows/publish-oci.yml").read_text())
        oci_regex = next(step["env"]["OPENBAO_SIGNING_ALLOWED_REFS_REGEX"]
                         for step in publish_oci["jobs"]["publish"]["steps"]
                         if "OPENBAO_SIGNING_ALLOWED_REFS_REGEX" in step.get("env", {}))
        names = [step["name"] for step in publish["steps"]]
        sign = next(step for step in publish["steps"] if "sign-oci-publish.sh" in step.get("run", ""))
        self.assertEqual(sign["env"]["OPENBAO_SIGNING_ALLOWED_REFS_REGEX"], oci_regex)
        for ref, admitted in (("refs/heads/staging", True), ("refs/heads/test/demo-test-12", True),
                              ("refs/heads/test/demo-test-x", False), ("refs/heads/feature", False)):
            self.assertEqual(bool(re.search(oci_regex, ref)), admitted, ref)

        # The bundle is verified before any credential exists, the push follows, and the
        # summary that reports success is written only after signing and promotion.
        self.assertLess(names.index("Verify the bundle against the build output"),
                        names.index("Prepare scoped Harbor publishing and verified promotion"))
        self.assertLess(names.index("Assemble and push to the build project"), names.index(sign["name"]))
        script = sign["run"]
        signed = script.index("./scripts/sign-oci-publish.sh")
        self.assertLess(script.index("source ./scripts/ci/prepare-openbao-cosign-env.sh"), signed)
        self.assertLess(signed, script.index("promote --repositories"))
        self.assertLess(script.index("promote --repositories"), script.index("GITHUB_STEP_SUMMARY"))
        self.assertTrue(script.startswith("set -euo pipefail"))

        native = re.search(r'SERVICERADAR_NATIVE_IMAGE="\$\{IMAGE\}"', script)
        self.assertIsNotNone(native)
        inventory = (ROOT / "docker/images/image_inventory.bzl").read_text()
        self.assertIn(f'"repository": "{self.workflow["env"]["IMAGE"]}"', inventory)


class MediaWorkerCudaBundleTest(unittest.TestCase):
    def setUp(self):
        self.tool = load_image_tool()
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.bundle = Path(self.directory.name)
        files = {"serviceradar-media-worker": b"synthetic-binary"}
        for library in self.tool.REQUIRED_LIBRARIES:
            files[f"lib/{library}"] = f"synthetic {library}".encode()
        binary_sha = hashlib.sha256(files["serviceradar-media-worker"]).hexdigest()
        files["manifest.json"] = json.dumps({"binary": {"sha256": binary_sha}}).encode()
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
        listed = self.tool.verify(self.bundle, self.sums_sha256)
        self.assertIn("lib/libcublasLt.so.13", listed)

        with self.assertRaisesRegex(self.tool.BundleError, "digest the build job reported"):
            self.tool.verify(self.bundle, "0" * 64)

        tampered = self.bundle / "lib/libcudart.so.13"
        tampered.write_bytes(b"substituted")
        with self.assertRaisesRegex(self.tool.BundleError, "does not match SHA256SUMS"):
            self.tool.verify(self.bundle, self.sums_sha256)
        # Re-listing the substitute does not help: the build's digest no longer matches.
        self.write_sums()
        with self.assertRaisesRegex(self.tool.BundleError, "digest the build job reported"):
            self.tool.verify(self.bundle, self.sums_sha256)

    def test_verify_rejects_unlisted_unexpected_or_missing_files(self):
        cases = {
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
                    self.tool.verify(self.bundle, sums)

    def test_layer_is_reproducible_and_runs_as_the_service_user(self):
        listed = self.tool.verify(self.bundle, self.sums_sha256)
        first, second = self.bundle.parent / "a.tar", self.bundle.parent / "b.tar"
        for out in (first, second):
            self.tool.write_layer(self.bundle, listed, b"synthetic CA bundle\n", out)
        self.assertEqual(first.read_bytes(), second.read_bytes())

        with tarfile.open(first) as layer:
            members = {member.name: member for member in layer.getmembers()}
            binary = members["usr/local/bin/serviceradar-media-worker"]
            self.assertEqual((binary.mode, binary.uid), (0o755, 0))
            for library in self.tool.REQUIRED_LIBRARIES:
                self.assertIn(f"usr/local/lib/serviceradar-cuda/{library}", members)
            self.assertNotIn("usr/local/lib/serviceradar-cuda/libcuda.so.1", members)
            cache = members["var/cache/serviceradar-media-worker/cuda"]
            self.assertEqual((cache.isdir(), cache.uid), (True, 10001))
            passwd = layer.extractfile("etc/passwd").read().decode()
            self.assertIn("serviceradar:x:10001:10001:", passwd)
            self.assertEqual(layer.extractfile("etc/ssl/certs/ca-certificates.crt").read(),
                             b"synthetic CA bundle\n")
        self.assertEqual(self.tool.IMAGE_ENV["LD_LIBRARY_PATH"], "/usr/local/lib/serviceradar-cuda")
        self.assertNotIn("NVIDIA_VISIBLE_DEVICES", self.tool.IMAGE_ENV)

    def test_push_refuses_the_protected_project(self):
        with self.assertRaisesRegex(self.tool.BundleError, "build project"):
            self.tool.push(self.bundle, self.sums_sha256,
                           "registry.carverauto.dev/serviceradar/serviceradar-media-worker-cuda:sha-x", "x")


if __name__ == "__main__":
    unittest.main()
