#!/usr/bin/env python3
"""The canary agent's rendered agent.json must decode into the agent's config types.

The agent reads `edge_record_sender.max_bytes` into a Go uint64, and Go's
encoding/json refuses any number literal with a fraction or exponent for an
integer field. Helm reads values.yaml numbers as float64 and prints large ones in
exponent form, so the chart default would stop the agent before its first lease.
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

CANARY = {
    "edgeRecords.enabled": True,
    "edgeRecords.contractRegistry": {"registry_epoch": 1},
    "edgeRecords.agentSweepEnabled": True,
    "agent.runtimeStorage.enabled": True,
}


def render_agent_config(overrides):
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
            "suite": "edge record agent configuration",
            "templates": ["templates/serviceradar-config.yaml"],
            "release": {"name": "edge-test", "namespace": "edge-test"},
            "tests": [{
                "it": "canary",
                "set": overrides,
                "asserts": [{"matchSnapshot": {"path": "data"}}],
            }],
        }
        (tests / "edge_agent_test.yaml").write_text(json.dumps(suite), encoding="utf-8")
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
        snapshot_path = tests / "__snapshot__" / "edge_agent_test.yaml.snap"
        with snapshot_path.open(encoding="utf-8") as snapshot:
            snapshots = list(yaml.safe_load(snapshot)["canary"].values())
        if len(snapshots) != 1:
            raise AssertionError(f"expected one emitted snapshot, got {len(snapshots)}")
        return json.loads(yaml.safe_load(snapshots[0])["agent.json"])


class EdgeRecordAgentConfigTest(unittest.TestCase):
    def test_default_spool_limit_is_an_integer_literal(self):
        sender = render_agent_config(CANARY)["edge_record_sender"]
        self.assertIs(type(sender["max_bytes"]), int)
        self.assertEqual(sender["max_bytes"], 1024 ** 3)
        self.assertTrue(sender["enabled"])
        self.assertTrue(sender["sweep_enabled"])
        self.assertEqual(sender["spool_dir"], "/var/lib/serviceradar/agent/edge-records")

    def test_an_operator_spool_limit_keeps_its_exact_integer_value(self):
        sender = render_agent_config({**CANARY, "edgeRecords.maxSpoolBytes": 268435456})[
            "edge_record_sender"
        ]
        self.assertIs(type(sender["max_bytes"]), int)
        self.assertEqual(sender["max_bytes"], 256 * 1024 ** 2)


if __name__ == "__main__":
    unittest.main()
