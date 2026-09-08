#!/usr/bin/env python3

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile


SCRIPT = Path(__file__).resolve().parent / "assemble_bundle.py"


class AssembleBundleTest(unittest.TestCase):
    def test_creates_deterministic_bundle_and_metadata(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            manifest = tmp / "plugin.yaml"
            wasm = tmp / "plugin.wasm"
            schema = tmp / "config.schema.json"
            bundle = tmp / "bundle.zip"
            sha = tmp / "bundle.sha256"
            metadata = tmp / "bundle.metadata.json"

            manifest.write_text("id: demo\n", encoding="utf-8")
            wasm.write_bytes(b"\x00asm")
            schema.write_text('{"type":"object"}\n', encoding="utf-8")

            subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--bundle-out",
                    str(bundle),
                    "--sha-out",
                    str(sha),
                    "--metadata-out",
                    str(metadata),
                    "--plugin-id",
                    "demo-plugin",
                    "--repository-name",
                    "wasm-plugin-demo-plugin",
                    "--artifact-type",
                    "application/test",
                    "--bundle-media-type",
                    "application/zip",
                    "--upload-signature-media-type",
                    "application/test+json",
                    "--entry",
                    f"plugin.yaml={manifest}",
                    "--entry",
                    f"plugin.wasm={wasm}",
                    "--entry",
                    f"config.schema.json={schema}",
                ],
                check=True,
            )

            self.assertTrue(bundle.exists())
            self.assertTrue(sha.exists())
            self.assertTrue(metadata.exists())

            with zipfile.ZipFile(bundle) as zf:
                self.assertEqual(zf.namelist(), ["config.schema.json", "plugin.wasm", "plugin.yaml"])
                self.assertEqual(zf.read("plugin.wasm"), b"\x00asm")

            metadata_json = json.loads(metadata.read_text(encoding="utf-8"))
            self.assertEqual(metadata_json["plugin_id"], "demo-plugin")
            self.assertEqual(metadata_json["repository_name"], "wasm-plugin-demo-plugin")
            self.assertEqual(metadata_json["bundle_file"], "bundle.zip")
            self.assertEqual(metadata_json["upload_signature_media_type"], "application/test+json")

    def test_derives_external_bundle_identity_from_manifest(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            manifest = tmp / "plugin.yaml"
            wasm = tmp / "plugin.wasm"
            schema = tmp / "config.schema.json"
            bundle = tmp / "example-inventory-0.1.0.zip"
            sha = tmp / "example-inventory-0.1.0.sha256"
            metadata = tmp / "example-inventory-0.1.0.metadata.json"
            commit = "a" * 40

            manifest.write_text(
                "id: example-inventory\nname: Example Inventory\nversion: 0.1.0\n",
                encoding="utf-8",
            )
            wasm.write_bytes(b"\x00asm")
            schema.write_text('{"type":"object"}\n', encoding="utf-8")

            subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--bundle-out",
                    str(bundle),
                    "--sha-out",
                    str(sha),
                    "--metadata-out",
                    str(metadata),
                    "--derive-from-manifest",
                    "--source-commit",
                    commit,
                    "--source-committed-at",
                    "2026-07-13T12:00:00-05:00",
                    "--artifact-type",
                    "application/test",
                    "--bundle-media-type",
                    "application/zip",
                    "--upload-signature-media-type",
                    "application/test+json",
                    "--entry",
                    f"plugin.yaml={manifest}",
                    "--entry",
                    f"plugin.wasm={wasm}",
                    "--entry",
                    f"config.schema.json={schema}",
                ],
                check=True,
            )

            metadata_json = json.loads(metadata.read_text(encoding="utf-8"))
            self.assertEqual(metadata_json["plugin_id"], "example-inventory")
            self.assertEqual(metadata_json["plugin_name"], "Example Inventory")
            self.assertEqual(metadata_json["plugin_version"], "0.1.0")
            self.assertEqual(metadata_json["repository_name"], "wasm-plugin-example-inventory")
            self.assertEqual(metadata_json["source_commit"], commit)
            self.assertEqual(metadata_json["source_committed_at"], "2026-07-13T12:00:00-05:00")

    def test_rejects_symlink_bundle_source(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            target = tmp / "target.yaml"
            manifest = tmp / "plugin.yaml"
            target.write_text("id: demo\n", encoding="utf-8")
            manifest.symlink_to(target)

            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--bundle-out",
                    str(tmp / "bundle.zip"),
                    "--sha-out",
                    str(tmp / "bundle.sha256"),
                    "--metadata-out",
                    str(tmp / "bundle.metadata.json"),
                    "--plugin-id",
                    "demo",
                    "--repository-name",
                    "wasm-plugin-demo",
                    "--artifact-type",
                    "application/test",
                    "--bundle-media-type",
                    "application/zip",
                    "--upload-signature-media-type",
                    "application/test+json",
                    "--entry",
                    f"plugin.yaml={manifest}",
                ],
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("bundle source must be a regular file", result.stderr)


if __name__ == "__main__":
    unittest.main()
