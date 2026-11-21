"""Render chart templates for the Python chart tests.

helm-unittest's snapshot mode is the renderer, so these tests need no helm
binary (get.helm.sh is unreachable from the BuildBuddy runners) and see exactly
the manifests the chart unit suite sees.
"""

from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile

import yaml


def repo_root() -> Path:
    """Repo root, from the runfiles tree under Bazel and the source tree otherwise."""
    srcdir = os.environ.get("TEST_SRCDIR")
    workspace = os.environ.get("TEST_WORKSPACE")
    if srcdir and workspace:
        candidate = Path(srcdir) / workspace
        if candidate.is_dir():
            return candidate
    return Path(__file__).resolve().parent.parent.parent


CHART_DIR = repo_root() / "helm" / "serviceradar"


def render_templates(
    templates: list[str],
    overrides: dict,
    *,
    release: str = "serviceradar",
    namespace: str,
    source_chart: Path = CHART_DIR,
) -> dict[str, list[dict]]:
    """Render each template with `overrides` and return {template: [documents]}."""
    binary = Path(os.environ["SERVICERADAR_HELM_UNITTEST_BINARY"]).resolve()
    results: dict[str, list[dict]] = {}
    with tempfile.TemporaryDirectory(dir=os.environ.get("TEST_TMPDIR")) as tmp:
        chart = Path(tmp) / "chart"
        chart.mkdir()
        for entry in source_chart.iterdir():
            if entry.name in ("tests", "__snapshot__"):
                continue
            dest = chart / entry.name
            if entry.is_dir():
                shutil.copytree(entry, dest)
            elif entry.is_file():
                shutil.copy2(entry, dest)
        tests_dir = chart / "tests"
        tests_dir.mkdir()

        suite = {
            "suite": "render templates",
            "templates": templates,
            "release": {"name": release, "namespace": namespace},
            "tests": [
                {
                    "it": tpl,
                    "template": tpl,
                    "set": overrides,
                    "asserts": [{"matchSnapshot": {}}],
                }
                for tpl in templates
            ],
        }
        (tests_dir / "render_test.yaml").write_text(json.dumps(suite), encoding="utf-8")
        env = {k: v for k, v in os.environ.items() if not k.startswith("HELM_")}
        proc = subprocess.run(
            [str(binary), str(chart)],
            env=env,
            capture_output=True,
            text=True,
            timeout=120,
        )
        if proc.returncode != 0:
            raise AssertionError(
                f"Helm rendering failed for {source_chart}:\n{proc.stdout}\n{proc.stderr}"
            )

        snap_file = tests_dir / "__snapshot__" / "render_test.yaml.snap"
        raw_snaps = yaml.safe_load(snap_file.read_text(encoding="utf-8")) or {}
        for tpl in templates:
            docs = []
            for _, doc_yaml in sorted(raw_snaps.get(tpl, {}).items()):
                parsed = yaml.safe_load(doc_yaml)
                if isinstance(parsed, dict) and parsed.get("kind"):
                    docs.append(parsed)
            results[tpl] = docs
    return results


def render_document(template: str, overrides: dict, *, namespace: str, kind: str, name: str | None = None) -> dict:
    """Render one template and return its single document of `kind` (and `name`)."""
    docs = [
        doc for doc in render_templates([template], overrides, namespace=namespace)[template]
        if doc["kind"] == kind and (name is None or doc["metadata"]["name"] == name)
    ]
    if len(docs) != 1:
        raise AssertionError(f"expected one {kind} {name or ''} from {template}, got {len(docs)}")
    return docs[0]
