#!/usr/bin/env python3
"""The media worker the chart deploys announces the model identity core uses.

Core has no setting for the camera model identity. VisualIndexDispatcher stamps
its compiled defaults on every visual-index job, and SemanticSearch requests a
query embedding on media.rpc.visual_text_embed.v1.<embedder id>.<version>. The
worker rejects a job whose embedder id or dimension differs from its own and
answers only the subject built from its own identity, so a chart that pins a
different identity deploys a worker that indexes nothing and answers no search,
and fails no health check.

The chart therefore pins the worker's identity in templates/media-worker.yaml.
This test reads core's defaults from source and the identity from the rendered
Deployment, so a change on either side without the other fails here.
"""

from pathlib import Path
import json
import os
import re
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


REPO_ROOT = _repo_root()
CHART_DIR = REPO_ROOT / "helm" / "serviceradar"
DISPATCHER = (
    REPO_ROOT / "elixir" / "serviceradar_core" / "lib" / "serviceradar"
    / "camera" / "visual_index_dispatcher.ex"
)

# Core module attribute -> worker environment variable.
IDENTITY = {
    "default_detector_model_id": "SERVICERADAR_MEDIA_WORKER_DETECTOR_MODEL_ID",
    "default_detector_model_version": "SERVICERADAR_MEDIA_WORKER_DETECTOR_MODEL_VERSION",
    "default_embedder_model_id": "SERVICERADAR_MEDIA_WORKER_EMBEDDER_MODEL_ID",
    "default_embedder_model_version": "SERVICERADAR_MEDIA_WORKER_EMBEDDER_MODEL_VERSION",
    "default_embedding_dim": "SERVICERADAR_MEDIA_WORKER_EMBEDDING_DIM",
}

ENABLED_WORKER = {
    "mediaWorker.enabled": True,
    "mediaWorker.runtimeClassName": "nvidia",
    "mediaWorker.models.existingClaim": "synthetic-models",
    "mediaWorker.auth.existingSecret": "synthetic-media-worker-auth",
    "mediaWorker.auth.deploymentRef": "00000000-0000-4000-8000-000000000004",
    "mediaWorker.auth.generation": "1",
    "webNg.controlPlaneRuntime.mediaWorker.enabled": True,
    "webNg.controlPlaneRuntime.mediaWorker.existingSecret": "synthetic-media-worker-auth",
    "webNg.controlPlaneRuntime.mediaWorker.deploymentRef": "00000000-0000-4000-8000-000000000004",
    "webNg.controlPlaneRuntime.mediaWorker.generation": "1",
}


def core_identity() -> dict[str, str]:
    source = DISPATCHER.read_text(encoding="utf-8")
    identity = {}
    for attribute in IDENTITY:
        match = re.search(rf'^\s*@{attribute}\s+"?([^"\s]+)"?\s*$', source, re.M)
        if match is None:
            raise AssertionError(f"@{attribute} not found in {DISPATCHER}")
        identity[attribute] = match.group(1)
    return identity


def rendered_worker_env() -> dict[str, str]:
    """Consume helm-unittest's snapshot of the worker's container env."""
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
            "suite": "media worker identity",
            "templates": ["templates/media-worker.yaml"],
            "release": {"name": "identity-test", "namespace": "identity-test"},
            "tests": [{
                "it": "worker env",
                "set": ENABLED_WORKER,
                "documentSelector": {"path": "kind", "value": "Deployment"},
                "asserts": [{"matchSnapshot": {"path": "spec.template.spec.containers[0].env"}}],
            }],
        }
        (tests / "identity_test.yaml").write_text(json.dumps(suite), encoding="utf-8")
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
        snapshot_path = tests / "__snapshot__" / "identity_test.yaml.snap"
        with snapshot_path.open(encoding="utf-8") as snapshot:
            snapshots = list(yaml.safe_load(snapshot)["worker env"].values())
        if len(snapshots) != 1:
            raise AssertionError(f"expected one emitted snapshot, got {len(snapshots)}")
        return {
            entry["name"]: entry.get("value")
            for entry in yaml.safe_load(snapshots[0])
        }


class MediaWorkerModelIdentityTest(unittest.TestCase):
    def test_the_chart_worker_announces_cores_model_identity(self):
        core = core_identity()
        env = rendered_worker_env()
        for attribute, variable in IDENTITY.items():
            with self.subTest(core=attribute, worker=variable):
                self.assertEqual(env.get(variable), core[attribute])


if __name__ == "__main__":
    unittest.main()
