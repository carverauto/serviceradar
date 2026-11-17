#!/usr/bin/env python3
"""The runtime certificate rotation record (files/runtime-cert-rotation.py).

Core admits an adopted infrastructure certificate by recorded fingerprint and
records a reissued one only when this record names the fingerprint it replaced
(ServiceRadar.Edge.RuntimeCertificateRotation). A reissued certificate missing
from the record locks its component out of NATS; a key in the record would
publish it to every core replica.

The certificate blocks are invented bytes. The record hashes DER and never
parses X.509, so no real certificate is needed.
"""

import base64
import hashlib
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path


def _script() -> Path:
    srcdir = os.environ.get("TEST_SRCDIR")
    workspace = os.environ.get("TEST_WORKSPACE")
    if srcdir and workspace:
        candidate = Path(srcdir) / workspace / "helm/serviceradar/files/runtime-cert-rotation.py"
        if candidate.is_file():
            return candidate
    return Path(__file__).resolve().parent / "files" / "runtime-cert-rotation.py"


SPEC = importlib.util.spec_from_file_location("runtime_cert_rotation", _script())
rotation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(rotation)


def certificate(label: str) -> tuple[str, str]:
    der = f"invented certificate {label}".encode()
    body = base64.b64encode(der).decode()
    pem = f"-----BEGIN CERTIFICATE-----\n{body}\n-----END CERTIFICATE-----"
    return pem, hashlib.sha256(der).hexdigest()


def key(label: str) -> str:
    body = base64.b64encode(f"invented key {label}".encode()).decode()
    return f"-----BEGIN PRIVATE KEY-----\n{body}\n-----END PRIVATE KEY-----\n"


class RuntimeCertRotationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=os.environ.get("TEST_TMPDIR"))
        self.dir = Path(self.tmp.name) / "certs"
        self.dir.mkdir()
        self.snapshot = Path(self.tmp.name) / "snapshot.json"
        self.root, _ = certificate("root")

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, files: dict[str, str]):
        for name, contents in files.items():
            path = self.dir / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents)

    def generation(self, label: str) -> dict[str, str]:
        """One generator run: root kept, every leaf and key reissued."""
        core, _ = certificate(f"core {label}")
        tools, _ = certificate(f"tools {label}")
        agent, _ = certificate(f"agent {label}")
        return {
            "root.pem": self.root + "\n",
            "ca.crt": self.root + "\n",
            "core.pem": core + "\n",
            "core-key.pem": key(f"core {label}"),
            "tools.pem": tools + "\n",
            # The generator copies tools.pem to client.pem.
            "client.pem": tools + "\n",
            # A component chain file: the leaf, then the root.
            "agent-dir/agent-chain.pem": f"{agent}\n{self.root}\n",
            # A key file that also carries the certificate is never read.
            "combined.pem": key(f"combined {label}") + certificate(f"combined {label}")[0],
        }

    def rotate(self, before: dict[str, str], after: dict[str, str]) -> dict:
        self.write(before)
        rotation.snapshot(str(self.dir), str(self.snapshot))
        self.write(after)
        rotation.manifest(str(self.dir), str(self.snapshot))
        return json.loads((self.dir / rotation.MANIFEST).read_text())

    def test_names_every_reissued_certificate_with_the_one_it_replaced(self):
        record = self.rotate(self.generation("one"), self.generation("two"))

        expected = {
            (certificate(f"{name} one")[1], certificate(f"{name} two")[1], name)
            for name in ("core", "tools", "agent")
        }
        self.assertEqual(record["version"], 1)
        self.assertEqual(
            {(e["previous_fingerprint"], e["fingerprint"]) for e in record["certificates"]},
            {(previous, current) for previous, current, _ in expected},
        )
        # tools.pem and client.pem hold one certificate: one entry.
        self.assertEqual(len(record["certificates"]), 3)

        for entry in record["certificates"]:
            leaf, root = rotation.PEM_BLOCK.findall(entry["certificate_pem"])
            self.assertEqual(
                hashlib.sha256(base64.b64decode("".join(leaf.split()))).hexdigest(),
                entry["fingerprint"],
            )
            self.assertEqual(root, rotation.PEM_BLOCK.search(self.root).group(1))

    def test_never_carries_key_material_or_trust_anchors(self):
        record = self.rotate(self.generation("one"), self.generation("two"))

        text = json.dumps(record)
        self.assertNotIn("PRIVATE KEY", text)
        root_fingerprint = certificate("root")[1]
        combined = {certificate(f"combined {g}")[1] for g in ("one", "two")}
        for entry in record["certificates"]:
            self.assertNotEqual(entry["fingerprint"], root_fingerprint)
            self.assertNotIn(entry["fingerprint"], combined)

    def test_first_generation_and_unchanged_certificates_name_nothing(self):
        record = self.rotate({}, self.generation("one"))
        self.assertEqual(record["certificates"], [])

        record = self.rotate(self.generation("one"), self.generation("one"))
        self.assertEqual(record["certificates"], [])


if __name__ == "__main__":
    unittest.main()
