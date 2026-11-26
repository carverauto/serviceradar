"""A kept certificate that lacks a name it is now asked to carry is reissued
alone.

Turning on edge leaves adds a host name to the broker certificate. The
generator must put that name on the broker certificate without touching any
other certificate: under NATS certificate authorization every client
certificate is admitted by its recorded fingerprint, so a fleet-wide reissue
to change one server certificate is a needless risk.

The script is the chart's own files/generate-certs.sh, rendered here for the
template expressions it contains. An expression this renderer does not know
fails the test rather than being dropped.
"""
import hashlib
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parent / "files" / "generate-certs.sh"
LEAF_HOST = "leaf.example.com"
GATEWAY_HOST = "gateway.example.com"


def render(leaf_host="", gateway_host="", media_worker=False):
    text = SCRIPT.read_text(encoding="utf-8")
    text = text.replace("{{ .Release.Namespace }}", "example")
    text = text.replace(
        '{{ include "serviceradar.natsLeafCertSans" . }}',
        f",DNS:{leaf_host}" if leaf_host else "",
    )
    text = re.sub(
        r"\{\{- if \.Values\.agentGateway\.publicHostname \}\}(.*?)\{\{- end \}\}",
        lambda m: m.group(1) if gateway_host else "",
        text,
    )
    text = text.replace("{{ .Values.agentGateway.publicHostname }}", gateway_host)
    text = re.sub(
        r'\n?\{\{- if eq \(include "serviceradar\.vantageEnabled" \.\) "true" \}\}(.*?)\n?\{\{- end \}\}',
        lambda m: m.group(1) if media_worker else "",
        text,
        flags=re.DOTALL,
    )
    if "{{" in text:
        raise AssertionError("generate-certs.sh has a template expression this test does not render")
    return text


def run(cert_dir, script, **env):
    path = cert_dir.parent / "generate-certs.sh"
    path.write_text(script, encoding="utf-8")
    reissued = cert_dir.parent / "reissued"
    reissued.write_text("")
    subprocess.run(
        ["bash", str(path)],
        check=True,
        capture_output=True,
        env={**os.environ, "CERT_DIR": str(cert_dir), "REISSUED_LIST": str(reissued), **env},
    )
    return reissued.read_text().split()


def digests(cert_dir):
    return {
        str(path.relative_to(cert_dir)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(cert_dir.rglob("*"))
        if path.is_file() and path.suffix != ".srl"
    }


def names(cert):
    out = subprocess.run(
        ["openssl", "x509", "-in", str(cert), "-noout", "-ext", "subjectAltName"],
        check=True, capture_output=True, text=True,
    ).stdout
    return {entry.strip() for entry in out.splitlines()[1].split(",")}


def changed(before, after):
    return sorted(name for name in after if before.get(name) != after[name])


class RuntimeCertNamesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=os.environ.get("TEST_TMPDIR"))
        self.addCleanup(self.tmp.cleanup)
        self.certs = Path(self.tmp.name) / "certs"
        run(self.certs, render())
        self.issued = digests(self.certs)

    def test_unchanged_names_reissue_nothing(self):
        self.assertEqual(run(self.certs, render(), NAMES_ONLY="true"), [])
        self.assertEqual(digests(self.certs), self.issued)

    def test_a_new_broker_name_reissues_only_the_broker_certificate(self):
        reissued = run(self.certs, render(leaf_host=LEAF_HOST), NAMES_ONLY="true")

        self.assertEqual(reissued, ["nats.pem"])
        self.assertEqual(changed(self.issued, digests(self.certs)), ["nats-key.pem", "nats.pem"])
        self.assertIn(f"DNS:{LEAF_HOST}", names(self.certs / "nats.pem"))
        subprocess.run(
            ["openssl", "verify", "-CAfile", str(self.certs / "root.pem"), str(self.certs / "nats.pem")],
            check=True, capture_output=True,
        )

        # The name is now present, so the next upgrade keeps the certificate.
        settled = digests(self.certs)
        self.assertEqual(run(self.certs, render(leaf_host=LEAF_HOST), NAMES_ONLY="true"), [])
        self.assertEqual(digests(self.certs), settled)

    def test_a_removed_name_is_not_a_reason_to_reissue(self):
        run(self.certs, render(leaf_host=LEAF_HOST), NAMES_ONLY="true")
        settled = digests(self.certs)

        self.assertEqual(run(self.certs, render(), NAMES_ONLY="true"), [])
        self.assertEqual(digests(self.certs), settled)

    def test_the_pass_creates_nothing_that_is_missing(self):
        for name in (
            "bmp-collector.pem",
            "bmp-collector-key.pem",
            "cnpg-client.pem",
            "api-key",
            "ca.crt",
            "client.pem",
            "client-key.pem",
            "flow-client.crt",
            "flow-client.key",
            "netflow-collector.pem",
            "netflow-collector-key.pem",
            "flowgger.pem",
            "flowgger-key.pem",
            "otel.pem",
            "otel-key.pem",
        ):
            (self.certs / name).unlink()
        remaining = digests(self.certs)

        self.assertEqual(run(self.certs, render(), NAMES_ONLY="true"), [])
        self.assertEqual(digests(self.certs), remaining)

    def test_copies_follow_a_reissued_certificate(self):
        # log-collector.pem is also served as flowgger.pem and otel.pem. Shorten
        # its names by issuing it afresh with one fewer, then ask for the full set.
        short = render().replace(",DNS:serviceradar-otlp.example.svc.cluster.local", "")
        self.assertNotEqual(short, render())
        for name in ("log-collector.pem", "flowgger.pem", "otel.pem"):
            (self.certs / name).unlink()
        run(self.certs, short)
        self.assertEqual((self.certs / "otel.pem").read_bytes(), (self.certs / "log-collector.pem").read_bytes())
        before = digests(self.certs)

        self.assertEqual(run(self.certs, render(), NAMES_ONLY="true"), ["log-collector.pem"])

        self.assertEqual(
            changed(before, digests(self.certs)),
            ["flowgger-key.pem", "flowgger.pem", "log-collector-key.pem", "log-collector.pem", "otel-key.pem", "otel.pem"],
        )
        for copy in ("flowgger", "otel"):
            self.assertEqual((self.certs / f"{copy}.pem").read_bytes(), (self.certs / "log-collector.pem").read_bytes())
            self.assertEqual((self.certs / f"{copy}-key.pem").read_bytes(), (self.certs / "log-collector-key.pem").read_bytes())

    def test_media_worker_cert_follows_names_only_rules(self):
        # Missing media-worker cert is not created by the NAMES_ONLY pass.
        self.assertFalse((self.certs / "media-worker.pem").exists())
        self.assertEqual(run(self.certs, render(media_worker=True), NAMES_ONLY="true"), [])
        self.assertEqual(digests(self.certs), self.issued)

        # Issuing with media_worker=True adds only the worker keypair, and a
        # subsequent broker SAN addition leaves the worker cert untouched.
        run(self.certs, render(media_worker=True))
        with_worker = digests(self.certs)
        self.assertEqual(changed(self.issued, with_worker), ["media-worker-key.pem", "media-worker.pem"])
        reissued = run(self.certs, render(leaf_host=LEAF_HOST, media_worker=True), NAMES_ONLY="true")
        self.assertEqual(reissued, ["nats.pem"])
        self.assertEqual(changed(with_worker, digests(self.certs)), ["nats-key.pem", "nats.pem"])


if __name__ == "__main__":
    unittest.main()
