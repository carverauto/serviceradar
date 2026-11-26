#!/usr/bin/env python3
"""The media worker the chart deploys announces the model identity core uses.

Core has no setting for the camera model identity. VisualIndexDispatcher stamps
its compiled defaults on every visual-index job, and text-embedding requests
arrive on media.rpc.visual_text_embed.v1.<embedder id>.<version>. The
worker rejects a job whose embedder id or dimension differs from its own and
answers only the subject built from its own identity, so a chart that pins a
different identity deploys a worker that indexes nothing and answers no search,
and fails no health check.

The chart therefore pins the worker's identity in templates/media-worker.yaml.
This test reads core's defaults from source and the identity from the rendered
Deployment, so a change on either side without the other fails here.
"""

import re
import unittest

from chart_render import render_document, repo_root


DISPATCHER = (
    repo_root() / "elixir" / "serviceradar_core" / "lib" / "serviceradar"
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
    "mediaWorker.image.repository": "registry.carverauto.dev/serviceradar/serviceradar-media-worker-cuda",
    "mediaWorker.image.tag": "sha-0123456789abcdef0123456789abcdef01234567",
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
    deployment = render_document(
        "templates/media-worker.yaml", ENABLED_WORKER, namespace="identity-test", kind="Deployment",
    )
    return {
        entry["name"]: entry.get("value")
        for entry in deployment["spec"]["template"]["spec"]["containers"][0]["env"]
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
