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
    templates: list[str] | None,
    overrides: dict,
    *,
    release: str = "serviceradar",
    namespace: str,
    source_chart: Path = CHART_DIR,
    values_files: list[Path] = (),
    combined: bool = False,
) -> dict[str, list[dict]]:
    """Render each template with `values_files` (in order) then `overrides`, and
    return {template: [documents]}, or {"all": [documents]} when `combined`.
    Pass `templates=None` with `combined=True` to render the entire release,
    including nested templates and enabled subcharts under `charts/`."""
    if templates is None and not combined:
        raise ValueError("templates must be provided unless combined=True")
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
        values_refs = []
        for index, values_file in enumerate(values_files):
            name = f"values-{index}.yaml"
            shutil.copy2(values_file, tests_dir / name)
            values_refs.append(name)

        # One test per template keeps each template's documents apart, but every test
        # renders the whole chart; a single test over all templates is far cheaper when
        # the caller does not need them apart.
        tests = [
            {
                "it": tpl,
                "template": tpl,
                "set": overrides,
                "values": values_refs,
                "asserts": [{"matchSnapshot": {}}],
            }
            for tpl in templates
        ] if not combined else [{
            "it": "all",
            "set": overrides,
            "values": values_refs,
            "asserts": [{"matchSnapshot": {}}],
        }]
        suite = {
            "suite": "render templates",
            "release": {"name": release, "namespace": namespace},
            "tests": tests,
        }
        if templates is not None:
            suite["templates"] = templates
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
        for tpl in (["all"] if combined else templates):
            docs = []
            for _, doc_yaml in sorted(raw_snaps.get(tpl, {}).items()):
                parsed = yaml.safe_load(doc_yaml)
                if isinstance(parsed, dict) and parsed.get("kind"):
                    docs.append(parsed)
            results[tpl] = docs
    return results


def render_release(
    overrides: dict,
    *,
    release: str = "serviceradar",
    namespace: str,
    source_chart: Path = CHART_DIR,
    values_files: list[Path] = (),
) -> list[dict]:
    """Render every manifest in the release, including nested and subchart templates."""
    return render_templates(
        None,
        overrides,
        release=release,
        namespace=namespace,
        source_chart=source_chart,
        values_files=values_files,
        combined=True,
    )["all"]


def render_document(template: str, overrides: dict, *, namespace: str, kind: str, name: str | None = None) -> dict:
    """Render one template and return its single document of `kind` (and `name`)."""
    docs = [
        doc for doc in render_templates([template], overrides, namespace=namespace)[template]
        if doc["kind"] == kind and (name is None or doc["metadata"]["name"] == name)
    ]
    if len(docs) != 1:
        raise AssertionError(f"expected one {kind} {name or ''} from {template}, got {len(docs)}")
    return docs[0]
