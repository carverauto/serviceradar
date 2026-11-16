#!/usr/bin/env python3
"""The chart's datasvc role list grants writer to the components that write to it.

web-ng writes Zen rule bundles and uploads plugin and addon artifacts, and
agent-gateway uploads agent artifacts. datasvc enforces its role list, so each
must be listed as writer under the identity its certificate presents. The
identities follow the subject that files/generate-certs.sh issues:
CN=<component CN>,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US.
"""

from pathlib import Path
import json
import os
import shutil
import subprocess
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
SUBJECT_SUFFIX = ",OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"


def render_datasvc_config():
    """Consume helm-unittest's generated ConfigMap snapshot, without golden files."""
    binary = Path(os.environ["SERVICERADAR_HELM_UNITTEST_BINARY"]).resolve()
    with tempfile.TemporaryDirectory(dir=os.environ.get("TEST_TMPDIR")) as tmp:
        chart = Path(tmp) / "chart"
        chart.mkdir()
        for name in (
            "Chart.yaml", "values.yaml", "templates", "charts", "crds",
            "dashboards", "files",
        ):
            source = CHART_DIR / name
            if source.is_dir():
                shutil.copytree(source, chart / name)
            elif source.is_file():
                shutil.copy2(source, chart / name)
        tests = chart / "tests"
        tests.mkdir()
        suite = {
            "suite": "datasvc roles",
            "templates": ["templates/serviceradar-config.yaml"],
            "release": {"name": "datasvc-test", "namespace": "datasvc-test"},
            "tests": [{
                "it": "datasvc config",
                "asserts": [{"matchSnapshot": {"path": "data"}}],
            }],
        }
        (tests / "datasvc_roles_test.yaml").write_text(json.dumps(suite), encoding="utf-8")
        env = {
            key: value for key, value in os.environ.items()
            if not key.startswith("HELM_")
        }
        rendered = subprocess.run(
            [str(binary), str(chart)],
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
        )
        if rendered.returncode:
            raise AssertionError(f"Helm rendering failed:\n{rendered.stdout}{rendered.stderr}")
        snapshot_path = tests / "__snapshot__" / "datasvc_roles_test.yaml.snap"
        with snapshot_path.open(encoding="utf-8") as snapshot:
            snapshots = list(yaml.safe_load(snapshot)["datasvc config"].values())
        if len(snapshots) != 1:
            raise AssertionError(f"expected one emitted snapshot, got {len(snapshots)}")
        return json.loads(yaml.safe_load(snapshots[0])["datasvc.json"])


class DatasvcRbacRolesTest(unittest.TestCase):
    def test_web_ng_and_agent_gateway_are_writers(self):
        roles = render_datasvc_config()["rbac"]["roles"]
        for cn in ("serviceradar-web-ng", "serviceradar-agent-gateway"):
            identity = f"CN={cn}{SUBJECT_SUFFIX}"
            with self.subTest(identity=identity):
                matching = [rule for rule in roles if rule["identity"] == identity]
                self.assertEqual(matching, [{"identity": identity, "role": "writer"}])

    def test_log_collector_reads_only_rule_bundles(self):
        # The collector's only datasvc use is fetching its Zen rule bundles.
        roles = render_datasvc_config()["rbac"]["roles"]
        collector = [
            rule for rule in roles
            if rule["identity"] == f"CN=serviceradar-log-collector{SUBJECT_SUFFIX}"
            or rule["identity"].endswith("/sa/serviceradar-log-collector")
        ]
        self.assertEqual(len(collector), 2, collector)
        for rule in collector:
            with self.subTest(identity=rule["identity"]):
                self.assertEqual(rule["role"], "reader")
                self.assertEqual(rule.get("key_prefixes"), ["zen/rulesets/"])


if __name__ == "__main__":
    unittest.main()
