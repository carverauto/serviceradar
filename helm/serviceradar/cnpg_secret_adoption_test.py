#!/usr/bin/env python3
"""The secret-generator hook must leave CNPG credential Secrets adoptable by Helm.

An interrupted first install leaves cnpg-superuser / serviceradar-db-credentials
behind without Helm's ownership metadata, and the recovery `helm upgrade` then
refuses to import them (#6345). Helm adopts an existing object only when it
carries the annotations meta.helm.sh/release-name and
meta.helm.sh/release-namespace naming the release, and the label
app.kubernetes.io/managed-by=Helm. That contract is the oracle here.

The test renders the chart, takes the shipped `ensure_cnpg_secret` function out
of the generated Job script, and runs it against a fake Kubernetes API (a
`curl` stand-in on PATH that applies RFC 7386 merge patches to stored Secrets).
"""

from pathlib import Path
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml


def _repo_root() -> Path:
    srcdir = os.environ.get("TEST_SRCDIR")
    workspace = os.environ.get("TEST_WORKSPACE")
    if srcdir and workspace:
        candidate = Path(srcdir) / workspace
        if candidate.is_dir():
            return candidate
    return Path(__file__).resolve().parent.parent.parent


CHART_DIR = _repo_root() / "helm" / "serviceradar"
RELEASE = "adopt-release"
NAMESPACE = "adopt-ns"

FAKE_CURL = r'''
import json, os, sys

args = sys.argv[1:]
method, url, data, output, write_out = "GET", None, None, None, None
i = 0
while i < len(args):
    arg = args[i]
    if arg == "-X":
        method = args[i + 1]; i += 2; continue
    if arg in ("-d", "--data"):
        data = args[i + 1]; i += 2; continue
    if arg in ("-o", "--output"):
        output = args[i + 1]; i += 2; continue
    if arg in ("-w", "--write-out"):
        write_out = args[i + 1]; i += 2; continue
    if arg in ("--cacert", "--header", "-H"):
        i += 2; continue
    if arg.startswith("-"):
        i += 1; continue
    url = arg; i += 1

if data is not None and data.startswith("@"):
    with open(data[1:], encoding="utf-8") as handle:
        data = handle.read()

state_path = os.environ["FAKE_API_STATE"]
with open(state_path, encoding="utf-8") as handle:
    state = json.load(handle)

with open(os.environ["FAKE_API_LOG"], "a", encoding="utf-8") as log:
    log.write(json.dumps({"method": method, "url": url}) + "\n")


def merge(target, patch):
    if not isinstance(patch, dict):
        return patch
    target = dict(target) if isinstance(target, dict) else {}
    for key, value in patch.items():
        if value is None:
            target.pop(key, None)
        else:
            target[key] = merge(target.get(key), value)
    return target


prefix = "/api/v1/namespaces/" + os.environ["FAKE_API_NAMESPACE"] + "/secrets"
path = url.split("://", 1)[-1]
path = path[path.index("/"):]
body = {}
if method == "POST" and path == prefix:
    secret = json.loads(data)
    name = secret["metadata"]["name"]
    if name in state:
        code = 409
    else:
        state[name] = secret
        code, body = 201, secret
elif method == "PATCH" and path.startswith(prefix + "/"):
    name = path[len(prefix) + 1:]
    forced = os.environ.get("FAKE_API_PATCH_STATUS")
    if forced:
        code = int(forced)
    elif name not in state:
        code = 404
    else:
        state[name] = merge(state[name], json.loads(data))
        code, body = 200, state[name]
else:
    code = 404

with open(state_path, "w", encoding="utf-8") as handle:
    json.dump(state, handle)
if output and output != "/dev/null":
    with open(output, "w", encoding="utf-8") as handle:
        json.dump(body, handle)
if write_out:
    sys.stdout.write(write_out.replace("%{http_code}", str(code)))
'''


def b64(text):
    return base64.b64encode(text.encode()).decode()


def render_generator_script():
    binary = Path(os.environ["SERVICERADAR_HELM_UNITTEST_BINARY"]).resolve()
    with tempfile.TemporaryDirectory(dir=os.environ.get("TEST_TMPDIR")) as tmp:
        chart = Path(tmp) / "chart"
        chart.mkdir()
        for name in ("Chart.yaml", "values.yaml", "templates", "charts", "crds", "dashboards", "files"):
            source = CHART_DIR / name
            if source.is_dir():
                shutil.copytree(source, chart / name)
            elif source.is_file():
                shutil.copy2(source, chart / name)
        tests = chart / "tests"
        tests.mkdir()
        suite = {
            "suite": "secret generator script",
            "templates": ["templates/secret-generator-job.yaml"],
            "release": {"name": RELEASE, "namespace": NAMESPACE},
            "tests": [{
                "it": "script",
                "documentSelector": {"path": "kind", "value": "Job"},
                "asserts": [{"matchSnapshot": {"path": "spec.template.spec.containers[0].args"}}],
            }],
        }
        (tests / "generator_test.yaml").write_text(json.dumps(suite), encoding="utf-8")
        env = {k: v for k, v in os.environ.items() if not k.startswith("HELM_")}
        rendered = subprocess.run(
            [str(binary), str(chart)], env=env, capture_output=True, text=True, timeout=60,
        )
        if rendered.returncode:
            raise AssertionError(f"Helm rendering failed:\n{rendered.stdout}{rendered.stderr}")
        snapshot = tests / "__snapshot__" / "generator_test.yaml.snap"
        with snapshot.open(encoding="utf-8") as handle:
            emitted = list(yaml.safe_load(handle)["script"].values())
        if len(emitted) != 1:
            raise AssertionError(f"expected one emitted snapshot, got {len(emitted)}")
        return yaml.safe_load(emitted[0])[0]


def extract_function(script, name):
    """The definition runs from its header to the script's first call of it."""
    lines = script.splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() == f"{name}() {{")
    end = next(i for i in range(start + 1, len(lines)) if lines[i].startswith(f"{name} "))
    return "\n".join(lines[start:end])


class CnpgSecretAdoptionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.function = extract_function(render_generator_script(), "ensure_cnpg_secret")

    def run_ensure(self, state, patch_status=None):
        with tempfile.TemporaryDirectory(dir=os.environ.get("TEST_TMPDIR")) as tmp:
            directory = Path(tmp)
            curl = directory / "curl"
            curl.write_text(f"#!{sys.executable}\n{FAKE_CURL}", encoding="utf-8")
            curl.chmod(0o755)
            state_path = directory / "state.json"
            state_path.write_text(json.dumps(state), encoding="utf-8")
            env = dict(
                os.environ,
                PATH=str(directory) + os.pathsep + os.defpath,
                APISERVER="https://kubernetes.default.svc",
                TOKEN="synthetic-token",
                CACERT=str(directory / "ca.crt"),
                NAMESPACE=NAMESPACE,
                FAKE_API_NAMESPACE=NAMESPACE,
                FAKE_API_STATE=str(state_path),
                FAKE_API_LOG=str(directory / "requests.jsonl"),
            )
            if patch_status:
                env["FAKE_API_PATCH_STATUS"] = str(patch_status)
            script = "set -eu\n" + self.function + '\nensure_cnpg_secret cnpg-superuser postgres\n'
            result = subprocess.run(
                ["/bin/sh", "-c", script], env=env, capture_output=True, text=True, timeout=60,
            )
            requests = [
                json.loads(line)
                for line in (directory / "requests.jsonl").read_text(encoding="utf-8").splitlines()
            ]
            return result, json.loads(state_path.read_text(encoding="utf-8")), requests

    def assert_helm_owned(self, secret):
        metadata = secret["metadata"]
        self.assertEqual(metadata["annotations"]["meta.helm.sh/release-name"], RELEASE)
        self.assertEqual(metadata["annotations"]["meta.helm.sh/release-namespace"], NAMESPACE)
        self.assertEqual(metadata["labels"]["app.kubernetes.io/managed-by"], "Helm")

    def existing_unowned_secret(self):
        return {
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {"name": "cnpg-superuser", "labels": {"cnpg.io/reload": "true"}},
            "type": "Opaque",
            "data": {"username": b64("postgres"), "password": b64("synthetic-existing-pass")},
        }

    def test_existing_secret_is_adopted_without_changing_password(self):
        result, state, requests = self.run_ensure({"cnpg-superuser": self.existing_unowned_secret()})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        secret = state["cnpg-superuser"]
        self.assert_helm_owned(secret)
        self.assertEqual(secret["data"]["password"], b64("synthetic-existing-pass"))
        self.assertEqual(secret["metadata"]["labels"]["cnpg.io/reload"], "true")
        self.assertEqual([r["method"] for r in requests], ["POST", "PATCH"])

    def test_rejected_ownership_patch_fails_the_hook(self):
        for status in (403, 422):
            with self.subTest(status=status):
                result, state, _ = self.run_ensure(
                    {"cnpg-superuser": self.existing_unowned_secret()}, patch_status=status,
                )
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn("annotations", state["cnpg-superuser"]["metadata"])

    def test_missing_secret_is_created_helm_owned(self):
        result, state, requests = self.run_ensure({})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        secret = state["cnpg-superuser"]
        self.assert_helm_owned(secret)
        self.assertEqual(base64.b64decode(secret["data"]["username"]).decode(), "postgres")
        self.assertEqual(len(base64.b64decode(secret["data"]["password"])), 32)
        self.assertEqual([r["method"] for r in requests], ["POST"])


if __name__ == "__main__":
    unittest.main()
