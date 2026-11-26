#!/usr/bin/env python3
"""The runtime certificate generator issues the Vantage addon media worker's NATS identity.

The broker maps a client certificate's subject to a static NATS user
(verify_and_map), and core adopts the chart's identities from the subject list
in the static-users ConfigMap. So the worker connects as itself only if the
generator issues a certificate with exactly the subject that list names, for a
key it also writes, signed by the runtime root; and an installation that
enables the worker later gets it only if the generator Job then requires it.

The test runs the generator script embedded in the rendered Job with openssl,
and the rendered Job's own preserve decision (its Secret download and check
script, with its rendered required files) against a fake Kubernetes API that
serves a synthetic Secret. The decision is read from the message the check
prints for it, so a crash cannot pass for "regenerate".
"""

import base64
import json
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
ENABLED = {"vantage.enabled": True}
DISABLED = {"vantage.enabled": False}
WORKER_CERT = "media-worker.pem"
VANTAGE_CERT = "vantage.pem"
VANTAGE_IDENTITIES = (
    ("serviceradar-media-worker", WORKER_CERT, "media-worker-key.pem"),
    ("serviceradar-vantage", VANTAGE_CERT, "vantage-key.pem"),
)


def generator_job(values):
    """The Job's embedded generate-certs.sh, its required files, its environment and
    its whole script."""
    job = render_document(
        "templates/cert-generator-job.yaml", values, namespace=NAMESPACE, kind="Job",
    )
    container = job["spec"]["template"]["spec"]["containers"][0]
    embedded = re.search(r"<<'EOF_SCRIPT_B64'\n(.*?)\nEOF_SCRIPT_B64", container["command"][2], re.S)
    if embedded is None:
        raise AssertionError("embedded generator not found in the Job script")
    generator = base64.b64decode("".join(embedded.group(1).split())).decode("utf-8")
    env = {item["name"]: item["value"] for item in container["env"] if "value" in item}
    # Kubernetes expands $(VAR) in args from the container's environment.
    required = [
        re.sub(r"\$\((\w+)\)", lambda m: env[m.group(1)], arg)
        for arg in container.get("args") or []
    ]
    return generator, required, env, container["command"][2]


def preserve_decision_script(job_script):
    """The rendered Job's script up to where it would regenerate, ending there."""
    head, sep, _ = job_script.partition("export FORCE_REGENERATE=true")
    if not sep:
        raise AssertionError("regeneration step not found in the Job script")
    return head + "\necho REGENERATE\nexit 3\n"


# Replaces the Kubernetes API for the Job's Secret download: sitecustomize runs at
# Python start-up, serving FAKE_SECRET_JSON and skipping TLS set-up.
FAKE_API = """
import io, os, ssl, urllib.request
if os.environ.get("FAKE_SECRET_JSON"):
    ssl.create_default_context = lambda *args, **kwargs: None
    _secret = open(os.environ["FAKE_SECRET_JSON"], "rb").read()
    urllib.request.urlopen = lambda request, context=None: io.BytesIO(_secret)
"""


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
    (Path(cert_dir) / "runtime-cert-layout-version").write_text(job_env["RUNTIME_CERT_LAYOUT_VERSION"])


def openssl(*args):
    return subprocess.run(
        ["openssl", *args], check=True, capture_output=True, text=True,
    ).stdout.strip()


class RuntimeCertMediaWorkerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(dir=os.environ.get("TEST_TMPDIR"))
        root = Path(cls.tmp.name)
        cls.enabled_script, cls.enabled_required, cls.enabled_env, cls.enabled_job = generator_job(ENABLED)
        cls.disabled_script, cls.disabled_required, cls.disabled_env, _ = generator_job(DISABLED)
        cls.enabled_certs = root / "enabled"
        cls.disabled_certs = root / "disabled"
        generate(cls.enabled_script, cls.enabled_env, cls.enabled_certs)
        generate(cls.disabled_script, cls.disabled_env, cls.disabled_certs)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_issues_the_listed_subject_for_its_key_under_the_root(self):
        enabled_subjects = chart_identity_subjects(ENABLED)
        for cn, cert_name, key_name in VANTAGE_IDENTITIES:
            with self.subTest(cn=cn):
                subjects = [
                    subject for subject in enabled_subjects
                    if subject.startswith(f"CN={cn},")
                ]
                self.assertEqual(len(subjects), 1)
                cert = self.enabled_certs / cert_name
                key = self.enabled_certs / key_name
                subject = openssl("x509", "-in", str(cert), "-noout", "-subject", "-nameopt", "RFC2253")
                self.assertEqual(subject, f"subject={subjects[0]}")
                san = openssl("x509", "-in", str(cert), "-noout", "-ext", "subjectAltName")
                self.assertIn(f"DNS:{cn}", san)
                self.assertIn(f"DNS:{cn}.{NAMESPACE}.svc.cluster.local", san)
                self.assertEqual(
                    openssl("x509", "-in", str(cert), "-noout", "-pubkey"),
                    openssl("pkey", "-in", str(key), "-pubout"),
                )
                openssl("verify", "-CAfile", str(self.enabled_certs / "root.pem"), str(cert))

    def test_requires_the_worker_pair_exactly_while_the_worker_is_enabled(self):
        # The pairs are required whether or not core projects the certificate
        # inventory: the Vantage workloads mount their cert/key pairs from this Secret.
        _, without_core, _, _ = generator_job({**ENABLED, "core.enabled": False})
        for _, cert_name, key_name in VANTAGE_IDENTITIES:
            for required in (self.enabled_required, without_core):
                self.assertIn(cert_name, required)
                self.assertIn(key_name, required)
            self.assertNotIn(cert_name, self.disabled_required)
            self.assertNotIn(key_name, self.disabled_required)

    def test_has_no_worker_identity_while_the_worker_is_off(self):
        disabled_subjects = chart_identity_subjects(DISABLED)
        for cn, cert_name, _ in VANTAGE_IDENTITIES:
            self.assertFalse((self.disabled_certs / cert_name).exists())
            self.assertFalse(any(
                subject.startswith(f"CN={cn},")
                for subject in disabled_subjects
            ))

    def decide(self, secret_files, *, secret_json=None):
        """Run the rendered Job's preserve decision against a Secret holding
        `secret_files` (a directory). Returns ("preserve",), ("missing", files) or
        ("invalid", files); anything else, a crash included, fails the test."""
        work = Path(tempfile.mkdtemp(dir=self.tmp.name))
        if secret_json is None:
            data = {}
            for path in secret_files.rglob("*"):
                if not path.is_file():
                    continue
                if path.name in data:
                    raise AssertionError(f"duplicate Secret key {path.name!r} under {secret_files}")
                data[path.name] = base64.b64encode(path.read_bytes()).decode("ascii")
            secret_json = json.dumps({
                "apiVersion": "v1",
                "kind": "Secret",
                "metadata": {"name": self.enabled_env["SECRET_NAME"]},
                "data": data,
            })
        (work / "secret.json").write_text(secret_json)
        sa = work / "sa"
        sa.mkdir()
        (sa / "token").write_text("synthetic-token")
        (sa / "namespace").write_text(NAMESPACE)
        (sa / "ca.crt").write_text("")
        site = work / "site"
        site.mkdir()
        (site / "sitecustomize.py").write_text(FAKE_API)
        job_tmp = work / "tmp"
        job_tmp.mkdir()
        script = (
            preserve_decision_script(self.enabled_job)
            .replace("/var/run/secrets/kubernetes.io/serviceaccount", str(sa))
            .replace("/tmp/", f"{job_tmp}/")
        )
        env = dict(
            os.environ,
            PYTHONPATH=str(site),
            FAKE_SECRET_JSON=str(work / "secret.json"),
            CERT_DIR=str(work / "certs"),
            **{k: self.enabled_env[k] for k in (
                "SECRET_NAME", "DEFAULT_PARTITION_ID", "DEFAULT_AGENT_COMPONENT_ID", "RUNTIME_CERT_LAYOUT_VERSION",
            )},
        )
        result = subprocess.run(
            ["bash", "-c", script, "runtime-cert-generator", *self.enabled_required],
            env=env, capture_output=True, text=True,
        )
        if result.returncode == 0 and "preserving current runtime certs" in result.stdout:
            return ("preserve",)
        if result.returncode == 3 and not result.stderr.strip():
            for reason, pattern in (
                ("missing", r"is missing runtime cert files: (.*)$"),
                ("invalid", r"do not verify against root.pem: (.*)$"),
            ):
                found = re.search(pattern, result.stdout, re.M)
                if found:
                    return (reason, sorted(found.group(1).split(", ")))
        return ("crash", result.returncode, result.stdout + result.stderr)

    def test_keeps_a_secret_that_holds_the_worker_pair(self):
        self.assertEqual(self.decide(self.enabled_certs), ("preserve",))

    def test_regenerates_a_secret_without_the_worker_pair_once_enabled(self):
        self.assertEqual(
            self.decide(self.disabled_certs),
            ("missing", ["media-worker-key.pem", WORKER_CERT, "vantage-key.pem", VANTAGE_CERT]),
        )

    def test_regenerates_a_worker_pair_kept_from_before_a_root_rotation(self):
        # Enabled, then disabled while the root was rotated: a fresh set without the
        # Vantage pairs is merged over the Secret, so the old pairs stay beside the new root.
        rotation = Path(self.tmp.name) / "rotation"
        generate(self.disabled_script, self.disabled_env, rotation, force=True)
        secret = Path(self.tmp.name) / "rotated-secret"
        shutil.copytree(self.enabled_certs, secret)
        for path in rotation.rglob("*"):
            if path.is_file():
                shutil.copy2(path, secret / path.relative_to(rotation))
        self.assertEqual(self.decide(secret), ("invalid", [WORKER_CERT, VANTAGE_CERT]))

    def test_preserves_an_expired_leaf_signed_by_the_current_root(self):
        secret = Path(self.tmp.name) / "expired-leaf-secret"
        shutil.copytree(self.enabled_certs, secret)
        ca_work = Path(self.tmp.name) / "expired-ca"
        ca_work.mkdir()
        (ca_work / "newcerts").mkdir()
        (ca_work / "index.txt").write_text("")
        (ca_work / "serial").write_text("1000\n")
        ca_cfg = ca_work / "ca.cnf"
        ca_cfg.write_text(
            "[ca]\n"
            "default_ca = ca_default\n"
            "[ca_default]\n"
            f"database = {ca_work / 'index.txt'}\n"
            f"serial = {ca_work / 'serial'}\n"
            f"new_certs_dir = {ca_work / 'newcerts'}\n"
            "default_md = sha256\n"
            "policy = policy_anything\n"
            "[policy_anything]\n"
            "commonName = supplied\n"
        )
        agent_id = self.enabled_env["DEFAULT_AGENT_COMPONENT_ID"]
        partition_id = self.enabled_env["DEFAULT_PARTITION_ID"]
        chain_name = f"{agent_id}-{partition_id}-chain.pem"
        openssl(
            "req", "-new", "-nodes", "-newkey", "rsa:2048",
            "-subj", f"/CN={agent_id}.{partition_id}.serviceradar",
            "-keyout", str(ca_work / "agent-key.pem"),
            "-out", str(ca_work / "agent.csr"),
        )
        openssl(
            "ca", "-batch", "-notext", "-config", str(ca_cfg),
            "-cert", str(secret / "root.pem"),
            "-keyfile", str(secret / "root-key.pem"),
            "-startdate", "20200101000000Z",
            "-enddate", "20200102000000Z",
            "-in", str(ca_work / "agent.csr"),
            "-out", str(ca_work / "expired-leaf.pem"),
        )
        chain_path = secret / "components" / chain_name
        self.assertTrue(chain_path.is_file(), f"expected generated chain at {chain_path}")
        chain_path.write_bytes(
            (ca_work / "expired-leaf.pem").read_bytes() + (secret / "root.pem").read_bytes()
        )
        time_checked = subprocess.run(
            ["openssl", "verify", "-CAfile", str(secret / "root.pem"), str(chain_path)],
            capture_output=True, text=True,
        )
        self.assertNotEqual(time_checked.returncode, 0, "test chain must actually be expired")
        self.assertEqual(self.decide(secret), ("preserve",))

    def test_reports_a_crash_rather_than_a_regeneration(self):
        decision = self.decide(self.enabled_certs, secret_json="{not json")
        self.assertEqual(decision[0], "crash")

    def test_regeneration_keeps_the_root_and_issues_the_worker_pair_under_it(self):
        # What the Job does once the check finds the pair missing after enabling.
        upgraded = Path(self.tmp.name) / "upgraded"
        shutil.copytree(self.disabled_certs, upgraded)
        generate(self.enabled_script, self.enabled_env, upgraded, force=True)
        self.assertEqual(
            (upgraded / "root.pem").read_bytes(), (self.disabled_certs / "root.pem").read_bytes(),
        )
        for _, cert_name, _ in VANTAGE_IDENTITIES:
            openssl("verify", "-CAfile", str(upgraded / "root.pem"), str(upgraded / cert_name))


if __name__ == "__main__":
    unittest.main()
