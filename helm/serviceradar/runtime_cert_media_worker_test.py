#!/usr/bin/env python3
"""The runtime certificate generator issues the media worker's NATS identity.

The broker maps a client certificate's subject to a static NATS user
(verify_and_map), and core adopts the chart's identities from the subject list
in the static-users ConfigMap. So the worker connects as itself only if the
generator issues a certificate with exactly the subject that list names, for a
key it also writes, signed by the runtime root; and an installation that
enables the worker later gets it only if the generator Job then requires it.

The test runs the generator script embedded in the rendered Job with openssl.
Whether the Job keeps or regenerates a given Secret is the check script's
contract, covered by runtime_cert_preservation_test.py; here the rendered
required-file list is checked to name the worker's certificate exactly while
the worker is enabled.
"""

import base64
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

from chart_render import render_document

NAMESPACE = "sr-cert-test"
ENABLED = {"mediaWorker.enabled": True}
DISABLED = {"mediaWorker.enabled": False}
WORKER_CERT = "media-worker.pem"


def generator_job(values):
    """The Job's embedded generate-certs.sh, its required files, and its environment."""
    job = render_document(
        "templates/cert-generator-job.yaml", values, namespace=NAMESPACE, kind="Job",
    )
    container = job["spec"]["template"]["spec"]["containers"][0]
    embedded = re.search(r"<<'EOF_SCRIPT_B64'\n(.*?)\nEOF_SCRIPT_B64", container["command"][2], re.S)
    if embedded is None:
        raise AssertionError("embedded generator not found in the Job script")
    generator = base64.b64decode("".join(embedded.group(1).split())).decode("utf-8")
    env = {item["name"]: item["value"] for item in container["env"] if "value" in item}
    return generator, container.get("args") or [], env


def chart_identity_subjects(values):
    config_map = render_document(
        "templates/nats.yaml", values, namespace=NAMESPACE,
        kind="ConfigMap", name="serviceradar-nats-static-users",
    )
    return yaml.safe_load(config_map["data"]["chart-identities.yaml"]) or []


def generate(script, job_env, cert_dir, *, force=False):
    """Run the generator as the Job does (FORCE_REGENERATE=true when it regenerates)."""
    env = dict(os.environ, CERT_DIR=str(cert_dir), FORCE_REGENERATE="true" if force else "false")
    for name in ("DEFAULT_PARTITION_ID", "DEFAULT_AGENT_COMPONENT_ID"):
        env[name] = job_env[name]
    subprocess.run(["bash", "-c", script], env=env, check=True, capture_output=True)


def openssl(*args):
    return subprocess.run(
        ["openssl", *args], check=True, capture_output=True, text=True,
    ).stdout.strip()


class RuntimeCertMediaWorkerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(dir=os.environ.get("TEST_TMPDIR"))
        root = Path(cls.tmp.name)
        cls.enabled_script, cls.enabled_required, cls.enabled_env = generator_job(ENABLED)
        cls.disabled_script, cls.disabled_required, cls.disabled_env = generator_job(DISABLED)
        cls.enabled_certs = root / "enabled"
        cls.disabled_certs = root / "disabled"
        generate(cls.enabled_script, cls.enabled_env, cls.enabled_certs)
        generate(cls.disabled_script, cls.disabled_env, cls.disabled_certs)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_issues_the_listed_subject_for_its_key_under_the_root(self):
        worker_subjects = [
            subject for subject in chart_identity_subjects(ENABLED)
            if subject.startswith("CN=serviceradar-media-worker,")
        ]
        self.assertEqual(len(worker_subjects), 1)
        cert = self.enabled_certs / WORKER_CERT
        key = self.enabled_certs / "media-worker-key.pem"
        subject = openssl("x509", "-in", str(cert), "-noout", "-subject", "-nameopt", "RFC2253")
        self.assertEqual(subject, f"subject={worker_subjects[0]}")
        self.assertEqual(
            openssl("x509", "-in", str(cert), "-noout", "-pubkey"),
            openssl("pkey", "-in", str(key), "-pubout"),
        )
        openssl("verify", "-CAfile", str(self.enabled_certs / "root.pem"), str(cert))

    def test_requires_the_worker_certificate_exactly_while_the_worker_is_enabled(self):
        self.assertIn(WORKER_CERT, self.enabled_required)
        self.assertNotIn(WORKER_CERT, self.disabled_required)

    def test_has_no_worker_identity_while_the_worker_is_off(self):
        self.assertFalse((self.disabled_certs / WORKER_CERT).exists())
        self.assertFalse(any(
            subject.startswith("CN=serviceradar-media-worker,")
            for subject in chart_identity_subjects(DISABLED)
        ))

    def test_regeneration_keeps_the_root_and_issues_the_worker_pair_under_it(self):
        # What the Job does once the check finds the pair missing after enabling.
        upgraded = Path(self.tmp.name) / "upgraded"
        shutil.copytree(self.disabled_certs, upgraded)
        generate(self.enabled_script, self.enabled_env, upgraded, force=True)
        self.assertEqual(
            (upgraded / "root.pem").read_bytes(), (self.disabled_certs / "root.pem").read_bytes(),
        )
        openssl("verify", "-CAfile", str(upgraded / "root.pem"), str(upgraded / WORKER_CERT))


if __name__ == "__main__":
    unittest.main()
