#!/usr/bin/env python3

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile


SCRIPT = Path(__file__).with_name("validate-external-wasm-plugin-bundle.py")
PLUGIN_ID = "example-inventory"
VERSION = "0.1.0"
COMMIT = "a" * 40


def write_fixture(root: Path):
    bundle = root / f"{PLUGIN_ID}-{VERSION}.zip"
    contents = {
        "config.schema.json": b'{"type":"object"}\n',
        "plugin.wasm": b"\x00asm\x01\x00\x00\x00",
        "docs/configuration.md": b"# Configuration\n",
        "plugin.yaml": f"id: {PLUGIN_ID}\nname: Example Inventory\nversion: {VERSION}\n".encode(),
    }
    with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, content in contents.items():
            archive.writestr(name, content)

    metadata = root / f"{PLUGIN_ID}-{VERSION}.metadata.json"
    metadata.write_text(
        json.dumps(
            {
                "artifact_type": "application/vnd.serviceradar.wasm-plugin.bundle.v1+zip",
                "bundle_file": bundle.name,
                "bundle_media_type": "application/zip",
                "entries": [{"archive_path": name, "source_path": name} for name in contents],
                "plugin_id": PLUGIN_ID,
                "plugin_version": VERSION,
                "repository_name": f"wasm-plugin-{PLUGIN_ID}",
                "sha256": hashlib.sha256(bundle.read_bytes()).hexdigest(),
                "source_commit": COMMIT,
                "upload_signature_media_type": "application/vnd.serviceradar.wasm-plugin.upload-signature.v1+json",
            }
        ),
        encoding="utf-8",
    )
    return metadata, bundle


def run_validator(metadata: Path, bundle: Path):
    return subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--metadata",
            str(metadata),
            "--bundle",
            str(bundle),
            "--plugin-id",
            PLUGIN_ID,
            "--version",
            VERSION,
            "--source-commit",
            COMMIT,
        ],
        capture_output=True,
        text=True,
        check=False,
    )


class ValidateExternalBundleTest(unittest.TestCase):
    def test_accepts_expected_bundle(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            metadata, bundle = write_fixture(Path(tmpdir))
            self.assertEqual(run_validator(metadata, bundle).returncode, 0)

    def test_rejects_bundle_path_from_untrusted_metadata(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            metadata, bundle = write_fixture(Path(tmpdir))
            document = json.loads(metadata.read_text(encoding="utf-8"))
            document["bundle_file"] = "../../service-account-token"
            metadata.write_text(json.dumps(document), encoding="utf-8")
            result = run_validator(metadata, bundle)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("metadata bundle_file", result.stderr)

    def test_rejects_unexpected_archive_entry(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            metadata, bundle = write_fixture(Path(tmpdir))
            with zipfile.ZipFile(bundle, "a") as archive:
                archive.writestr("unexpected", b"data")
            document = json.loads(metadata.read_text(encoding="utf-8"))
            document["sha256"] = hashlib.sha256(bundle.read_bytes()).hexdigest()
            metadata.write_text(json.dumps(document), encoding="utf-8")
            result = run_validator(metadata, bundle)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unsupported bundle entry", result.stderr)

    def test_rejects_unsupported_document_type(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            metadata, bundle = write_fixture(Path(tmpdir))
            with zipfile.ZipFile(bundle, "a") as archive:
                archive.writestr("docs/configuration.html", b"<script>alert(1)</script>")
            document = json.loads(metadata.read_text(encoding="utf-8"))
            document["entries"].append(
                {"archive_path": "docs/configuration.html", "source_path": "configuration.html"}
            )
            document["sha256"] = hashlib.sha256(bundle.read_bytes()).hexdigest()
            metadata.write_text(json.dumps(document), encoding="utf-8")
            result = run_validator(metadata, bundle)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unsupported bundle entry", result.stderr)


if __name__ == "__main__":
    unittest.main()
