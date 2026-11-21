import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


CHECK = Path(__file__).parent / "files" / "check-runtime-certs.py"
LAYOUT = "runtime-cert-layout-version"
# Every required leaf certificate is verified against root.pem, whichever
# identity it belongs to (the media worker's included); keys are not.
VERIFIED = ("trivy-sidecar.pem", "k8s-inventory.pem", "gateway.pem", "media-worker.pem")
REQUIRED = ("root.pem", *VERIFIED, "gateway-key.pem", LAYOUT)


class RuntimeCertPreservationTest(unittest.TestCase):
    def test_upgrade_decision(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get("TEST_TMPDIR")) as tmp:
            certs = Path(tmp)

            def openssl(*args):
                subprocess.run(["openssl", *args], cwd=certs, check=True, capture_output=True)

            openssl("req", "-new", "-x509", "-nodes", "-newkey", "rsa:2048",
                    "-subj", "/CN=Inventory Test Root", "-days", "1", "-addext",
                    "basicConstraints=critical,CA:TRUE",
                    "-keyout", "root-key.pem", "-out", "root.pem")
            openssl("req", "-new", "-nodes", "-newkey", "rsa:2048",
                    "-subj", "/CN=Inventory Test Client", "-keyout", "client-key.pem",
                    "-out", "client.csr")
            openssl("x509", "-req", "-in", "client.csr", "-CA", "root.pem",
                    "-CAkey", "root-key.pem", "-set_serial", "2", "-days", "1",
                    "-out", "client.pem")
            openssl("x509", "-req", "-in", "client.csr", "-signkey", "client-key.pem",
                    "-set_serial", "3", "-days", "1", "-out", "untrusted.pem")

            issued = (certs / "client.pem").read_bytes()
            for name in VERIFIED:
                (certs / name).write_bytes(issued)
            (certs / "gateway-key.pem").write_bytes((certs / "client-key.pem").read_bytes())
            (certs / LAYOUT).write_text("2")

            def check(expected_status, message):
                result = subprocess.run(
                    [sys.executable, CHECK, certs, "2", *REQUIRED],
                    env={**os.environ, "SECRET_NAME": "inventory-test"},
                    capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, expected_status, result.stdout + result.stderr)
                self.assertIn(message, result.stdout)

            check(0, "preserving current runtime certs")
            for name in ("gateway.pem", LAYOUT):
                with self.subTest(missing=name):
                    path = certs / name
                    contents = path.read_bytes()
                    path.unlink()
                    check(1, f"missing runtime cert files: {name}")
                    path.write_bytes(contents)

            # An untrusted leaf stands for one left from before a root rotation, for
            # example the media worker's pair kept while the worker was disabled.
            for name in VERIFIED:
                with self.subTest(untrusted=name):
                    (certs / name).write_bytes((certs / "untrusted.pem").read_bytes())
                    check(1, f"do not verify against root.pem: {name}")
                    (certs / name).write_bytes(issued)

            (certs / LAYOUT).write_text("1")
            check(1, "layout version 1; expected 2")


if __name__ == "__main__":
    unittest.main()
