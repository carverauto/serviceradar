#!/usr/bin/env python3

import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile


SCRIPT = Path(__file__).resolve().parent / "assemble_addon_bundle.py"


def fake_elf64(machine: int) -> bytes:
    header = bytearray(64)
    header[0:4] = b"\x7fELF"
    header[4] = 2  # ELFCLASS64
    header[5] = 1  # little endian
    header[6] = 1  # ELF version
    header[16:18] = (2).to_bytes(2, "little")  # ET_EXEC
    header[18:20] = machine.to_bytes(2, "little")
    return bytes(header) + b"\0payload"


def manifest_text() -> str:
    return """\
id: demo
name: Demo Addon
version: 0.1.0
kind: native
delivery: pushed-artifact
supervision: agent-sidecar
capabilities:
  - native-telemetry:v1
requires:
  agent: ">=1.0.0"
exec:
  command: ./demo-addon
config_schema: config.schema.json
"""


class AssembleAddonBundleTest(unittest.TestCase):
    def base_args(self, tmp: Path, binary: Path):
        manifest = tmp / "addon.yaml"
        schema = tmp / "config.schema.json"
        bundle = tmp / "bundle.zip"
        sha = tmp / "bundle.sha256"
        metadata = tmp / "bundle.metadata.json"
        tarball = tmp / "demo.linux.amd64.tar.gz"

        manifest.write_text(manifest_text(), encoding="utf-8")
        schema.write_text('{"type":"object"}\n', encoding="utf-8")

        return [
            sys.executable,
            str(SCRIPT),
            "--bundle-out",
            str(bundle),
            "--sha-out",
            str(sha),
            "--metadata-out",
            str(metadata),
            "--addon-id",
            "demo",
            "--repository-name",
            "serviceradar-addon-demo",
            "--artifact-type",
            "application/test",
            "--bundle-media-type",
            "application/zip",
            "--upload-signature-media-type",
            "application/test+json",
            "--entry",
            f"addon.yaml={manifest}",
            "--entry",
            f"config.schema.json={schema}",
            "--artifact",
            f"linux/amd64=bin/linux/amd64/demo-addon={binary}",
            "--tarball",
            f"linux/amd64={tarball}",
        ], bundle, sha, metadata, tarball

    def test_creates_bundle_for_matching_linux_amd64_elf(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            binary = tmp / "demo-addon"
            binary.write_bytes(fake_elf64(62))

            args, bundle, sha, metadata, tarball = self.base_args(tmp, binary)
            subprocess.run(args, check=True)

            self.assertTrue(bundle.exists())
            self.assertTrue(sha.exists())
            self.assertTrue(metadata.exists())
            self.assertTrue(tarball.exists())

            with zipfile.ZipFile(bundle) as zf:
                self.assertIn("bin/linux/amd64/demo-addon", zf.namelist())
                self.assertEqual(zf.read("bin/linux/amd64/demo-addon"), binary.read_bytes())

            with tarfile.open(tarball, "r:gz") as tf:
                self.assertEqual(sorted(tf.getnames()), ["addon.yaml", "config.schema.json", "demo-addon"])

            metadata_json = json.loads(metadata.read_text(encoding="utf-8"))
            self.assertEqual(metadata_json["artifacts"][0]["os"], "linux")
            self.assertEqual(metadata_json["artifacts"][0]["arch"], "amd64")
            self.assertEqual(metadata_json["artifacts"][0]["tarball_file"], tarball.name)

    def test_rejects_mislabeled_non_elf_artifact(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            binary = tmp / "demo-addon"
            binary.write_bytes(b"\xcf\xfa\xed\xfe" + b"mach-o")

            args, bundle, sha, metadata, tarball = self.base_args(tmp, binary)
            result = subprocess.run(args, check=False, capture_output=True, text=True)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("expected linux/amd64 ELF executable", result.stderr)
            self.assertFalse(bundle.exists())
            self.assertFalse(sha.exists())
            self.assertFalse(metadata.exists())
            self.assertFalse(tarball.exists())

    def test_rejects_wrong_elf_machine(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            binary = tmp / "demo-addon"
            binary.write_bytes(fake_elf64(183))

            args, _bundle, _sha, _metadata, _tarball = self.base_args(tmp, binary)
            result = subprocess.run(args, check=False, capture_output=True, text=True)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("expected linux/amd64 ELF machine 62, got 183", result.stderr)


if __name__ == "__main__":
    unittest.main()
