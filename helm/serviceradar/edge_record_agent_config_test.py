#!/usr/bin/env python3
"""The bundled agent's rendered agent.json names only where its edge-record spool lives.

The pipeline has no chart values: the sender and spool always run and core delivers
the spool budget. The chart still owns the agent's runtime volume
(agent.runtimeStorage), so it tells the agent to keep its spool on that volume. A
spool anywhere else would sit on the container's writable layer and lose every
unsent record when the pod is replaced.
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
                "it": "agent config",
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
            snapshots = list(yaml.safe_load(snapshot)["agent config"].values())
        if len(snapshots) != 1:
            raise AssertionError(f"expected one emitted snapshot, got {len(snapshots)}")
        return json.loads(yaml.safe_load(snapshots[0])["agent.json"])


class EdgeRecordAgentConfigTest(unittest.TestCase):
    def test_default_values_place_the_spool_on_the_runtime_volume_and_nothing_else(self):
        sender = render_agent_config({})["edge_record_sender"]
        self.assertEqual(sender, {"spool_dir": "/var/lib/serviceradar/agent/edge-records"})

    def test_the_spool_follows_a_moved_runtime_volume(self):
        sender = render_agent_config({"agent.runtimeStorage.basePath": "/srv/agent-runtime"})[
            "edge_record_sender"
        ]
        self.assertEqual(sender, {"spool_dir": "/srv/agent-runtime/edge-records"})


if __name__ == "__main__":
    unittest.main()
