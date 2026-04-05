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


if __name__ == "__main__":
    unittest.main()
