#!/usr/bin/env python3
"""The runtime certificate generator issues the media worker's NATS identity.

The broker maps a client certificate's subject to a static NATS user
(verify_and_map), so the worker connects as CN=serviceradar-media-worker only
if the generator issues a certificate with exactly that user's subject, for a
key it also writes, signed by the runtime root.

The generator Job keeps an existing runtime Secret unless a file it requires
is missing, so an installation that enables the worker after its first install
gets the certificate only if the Job then treats the Secret as incomplete.

The test runs the generator script embedded in the rendered Job with openssl,
and the Job's rendered preserve check against a fake Kubernetes API that serves
a synthetic Secret. The oracle for the subject is the static user the chart
renders for the broker; the preserve check's decision is read from the message
it prints for that decision, so a crash cannot pass for "regenerate".
"""

import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

from chart_render import render_document

NAMESPACE = "sr-cert-test"
ENABLED = {"mediaWorker.enabled": True}
DISABLED = {"mediaWorker.enabled": False}

# Replaces the Kubernetes API for the Job's preserve check: urlopen serves the
# Secret in FAKE_SECRET_JSON and the service-account files come from FAKE_SA_DIR.
FAKE_API = '''
import io, os, ssl, urllib.request
ssl.create_default_context = lambda *args, **kwargs: None
_secret = open(os.environ["FAKE_SECRET_JSON"], "rb").read()
urllib.request.urlopen = lambda request, context=None: io.BytesIO(_secret)
'''


def generator_inputs(values):
    """The Job's embedded generate-certs.sh, its preserve check, and its environment."""
    job = render_document(
        "templates/cert-generator-job.yaml", values, namespace=NAMESPACE, kind="Job",
    )
    container = job["spec"]["template"]["spec"]["containers"][0]
    script = container["args"][0]
    check = re.search(r"if python3 <<'PY'\n(.*?)\nPY\nthen", script, re.S)
    embedded = re.search(r"<<'EOF_SCRIPT_B64'\n(.*?)\nEOF_SCRIPT_B64", script, re.S)
    if check is None or embedded is None:
        raise AssertionError("preserve check or embedded generator not found in the Job script")
    generator = base64.b64decode("".join(embedded.group(1).split())).decode("utf-8")
    env = {item["name"]: item["value"] for item in container["env"] if "value" in item}
    return generator, check.group(1), env


def generate(script, job_env, cert_dir, *, force=False):
    """Run the generator as the Job does (FORCE_REGENERATE=true after a failed check)."""
    env = dict(os.environ, CERT_DIR=str(cert_dir), FORCE_REGENERATE="true" if force else "false")
    for name in ("DEFAULT_PARTITION_ID", "DEFAULT_AGENT_COMPONENT_ID"):
        env[name] = job_env[name]
    subprocess.run(["bash", "-c", script], env=env, check=True, capture_output=True)
    (cert_dir / "runtime-cert-layout-version").write_text(job_env["RUNTIME_CERT_LAYOUT_VERSION"])


def openssl(*args):
    return subprocess.run(
        ["openssl", *args], check=True, capture_output=True, text=True,
    ).stdout.strip()


def media_worker_user():
    config_map = render_document(
        "templates/nats.yaml", ENABLED, namespace=NAMESPACE,
        kind="ConfigMap", name="serviceradar-nats-static-users",
    )
    users = yaml.safe_load(config_map["data"]["static-users.yaml"])
    (user,) = [u["user"] for u in users if u["user"].startswith("CN=serviceradar-media-worker,")]
    return user


class RuntimeCertMediaWorkerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(dir=os.environ.get("TEST_TMPDIR"))
        root = Path(cls.tmp.name)
        cls.enabled_script, cls.enabled_check, cls.enabled_env = generator_inputs(ENABLED)
        cls.disabled_script, cls.disabled_check, cls.disabled_env = generator_inputs(DISABLED)
        cls.enabled_certs = root / "enabled"
        cls.disabled_certs = root / "disabled"
        generate(cls.enabled_script, cls.enabled_env, cls.enabled_certs)
        generate(cls.disabled_script, cls.disabled_env, cls.disabled_certs)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def preserves(self, check, job_env, secret_dir):
        """True when the Job keeps the Secret; the missing files when it regenerates it."""
        work = Path(tempfile.mkdtemp(dir=self.tmp.name))
        data = {
            path.name: base64.b64encode(path.read_bytes()).decode("ascii")
            for path in secret_dir.rglob("*") if path.is_file()
        }
        (work / "secret.json").write_text(json.dumps({"data": data}))
        sa = work / "sa"
        sa.mkdir()
        (sa / "token").write_text("synthetic-token")
        (sa / "namespace").write_text(NAMESPACE)
        (sa / "ca.crt").write_text("")
        script = FAKE_API + check.replace("/var/run/secrets/kubernetes.io/serviceaccount", str(sa))
        env = dict(
            os.environ,
            FAKE_SECRET_JSON=str(work / "secret.json"),
            SECRET_NAME="serviceradar-runtime-certs",
            CERT_DIR=str(work / "certs"),
            **{k: job_env[k] for k in (
                "DEFAULT_PARTITION_ID", "DEFAULT_AGENT_COMPONENT_ID", "RUNTIME_CERT_LAYOUT_VERSION",
            )},
        )
        result = subprocess.run([sys.executable, "-c", script], env=env, capture_output=True, text=True)
        if result.returncode == 0 and "preserving current runtime certs" in result.stdout:
            return True
        missing = re.search(r"is missing runtime cert files: (.*)$", result.stdout, re.M)
        if result.returncode == 1 and missing and not result.stderr.strip():
            return missing.group(1).split(", ")
        raise AssertionError(
            f"preserve check reached neither decision (exit {result.returncode}):\n"
            f"{result.stdout}{result.stderr}"
        )

    def test_issues_the_subject_the_broker_maps_for_its_key_under_the_root(self):
        cert = self.enabled_certs / "media-worker.pem"
        key = self.enabled_certs / "media-worker-key.pem"
        subject = openssl("x509", "-in", str(cert), "-noout", "-subject", "-nameopt", "RFC2253")
        self.assertEqual(subject, f"subject={media_worker_user()}")
        self.assertEqual(
            openssl("x509", "-in", str(cert), "-noout", "-pubkey"),
            openssl("pkey", "-in", str(key), "-pubout"),
        )
        openssl("verify", "-CAfile", str(self.enabled_certs / "root.pem"), str(cert))

    def test_issues_no_worker_certificate_while_the_worker_is_off(self):
        self.assertFalse((self.disabled_certs / "media-worker.pem").exists())
        self.assertFalse((self.disabled_certs / "media-worker-key.pem").exists())

    def test_regenerates_a_secret_without_the_worker_pair_once_the_worker_is_enabled(self):
        self.assertEqual(
            self.preserves(self.enabled_check, self.enabled_env, self.disabled_certs),
            ["media-worker.pem", "media-worker-key.pem"],
        )

    def test_regeneration_keeps_the_root_and_issues_the_worker_pair_under_it(self):
        upgraded = Path(self.tmp.name) / "upgraded"
        shutil.copytree(self.disabled_certs, upgraded)
        generate(self.enabled_script, self.enabled_env, upgraded, force=True)
        self.assertEqual(
            (upgraded / "root.pem").read_bytes(), (self.disabled_certs / "root.pem").read_bytes(),
        )
        openssl("verify", "-CAfile", str(upgraded / "root.pem"), str(upgraded / "media-worker.pem"))

    def test_keeps_a_secret_that_already_holds_the_worker_pair(self):
        self.assertIs(self.preserves(self.enabled_check, self.enabled_env, self.enabled_certs), True)

    def test_keeps_a_secret_without_the_worker_pair_while_the_worker_is_off(self):
        self.assertIs(self.preserves(self.disabled_check, self.disabled_env, self.disabled_certs), True)


if __name__ == "__main__":
    unittest.main()
