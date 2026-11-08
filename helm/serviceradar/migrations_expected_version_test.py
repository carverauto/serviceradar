#!/usr/bin/env python3
"""Drift guard for the `wait-migrations` init container's schema-version check.

web-ng's init container used to accept any database that merely *had* a
platform.schema_migrations table. That passes against a schema left behind by a
skipped migration hook -- `helm upgrade --no-hooks` skips
serviceradar-core-migrations, which is a pre-upgrade hook -- so web-ng would
start, fail on tables its release expects, and the operator would see an OOM or
a crashloop instead of "your schema is stale".

The init container now compares the applied high-water mark against
core.migrations.expectedVersion. That value is only meaningful while it tracks
the migrations actually shipped, which is what this test enforces.

//rust/integration-db does the same comparison for the test-database template
(see the :migrations filegroup comment in
elixir/serviceradar_core/BUILD.bazel); this is the chart-side counterpart.
"""

from pathlib import Path
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest

import yaml


def _repo_root() -> Path:
    """Repo root, from the runfiles tree under Bazel and the source tree otherwise.

    Preferring TEST_SRCDIR keeps this working on RBE, where there is no source
    tree beside the runfiles for Path.resolve() to land back in.
    """
    srcdir = os.environ.get("TEST_SRCDIR")
    workspace = os.environ.get("TEST_WORKSPACE")
    if srcdir and workspace:
        candidate = Path(srcdir) / workspace
        if candidate.is_dir():
            return candidate
    return Path(__file__).resolve().parent.parent.parent


REPO_ROOT = _repo_root()
CHART_DIR = REPO_ROOT / "helm" / "serviceradar"
VALUES = CHART_DIR / "values.yaml"
MIGRATIONS_DIR = (
    REPO_ROOT / "elixir" / "serviceradar_core" / "priv" / "repo" / "migrations"
)

VERSION_RE = re.compile(r"^(\d{14})_")


def newest_migration_version() -> str:
    versions = sorted(
        match.group(1)
        for path in MIGRATIONS_DIR.glob("*.exs")
        if (match := VERSION_RE.match(path.name))
    )
    if not versions:
        raise AssertionError(f"no migrations found under {MIGRATIONS_DIR}")
    return versions[-1]


class MigrationsExpectedVersionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with VALUES.open(encoding="utf-8") as values:
            cls.expected = yaml.safe_load(values)["core"]["migrations"]["expectedVersion"]
        cls.rendered = cls.render_init_containers()

    @classmethod
    def render_init_containers(cls):
        """Consume helm-unittest's generated manifest snapshots, without golden files."""
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
                "suite": "migration guard executable configuration",
                "templates": [
                    "templates/web.yaml",
                    "templates/core.yaml",
                    "templates/core-migrations-job.yaml",
                ],
                "release": {"name": "schema-test", "namespace": "schema-test"},
                "tests": [
                    {
                        "it": name,
                        "template": template,
                        "set": overrides,
                        "documentSelector": {"path": "kind", "value": kind},
                        "asserts": [{"matchSnapshot": {
                            "path": "spec.template.spec.initContainers",
                        }}],
                    }
                    for name, template, kind, overrides in (
                        ("default", "templates/web.yaml", "Deployment", {}),
                        ("empty", "templates/web.yaml", "Deployment", {"core.migrations.expectedVersion": ""}),
                        ("core_default", "templates/core.yaml", "Deployment", {}),
                        ("migrations_job", "templates/core-migrations-job.yaml", "Job", {}),
                    )
                ],
            }
            (tests / "migration_guard_test.yaml").write_text(
                json.dumps(suite), encoding="utf-8",
            )
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
            snapshot_path = tests / "__snapshot__" / "migration_guard_test.yaml.snap"
            with snapshot_path.open(encoding="utf-8") as snapshot:
                manifests = yaml.safe_load(snapshot)
            containers = {}
            for name, expected_container in (
                ("default", "wait-migrations"),
                ("empty", "wait-migrations"),
                ("core_default", "wait-migrations"),
                ("migrations_job", "wait-for-cnpg"),
            ):
                snapshots = list(manifests[name].values())
                if len(snapshots) != 1:
                    raise AssertionError(f"expected one emitted snapshot for {name}")
                emitted = yaml.safe_load(snapshots[0]) or []
                matching = [
                    container for container in emitted
                    if container["name"] == expected_container
                ]
                if len(matching) != 1:
                    raise AssertionError(
                        f"expected one {expected_container} container in {name}, got {matching}"
                    )
                containers[name] = matching[0]
            return containers

    def test_expected_version_matches_newest_shipped_migration(self):
        self.assertEqual(
            self.expected,
            newest_migration_version(),
            "core.migrations.expectedVersion must match the newest shipped migration",
        )
        for key in ("default", "core_default"):
            env = {
                entry["name"]: entry.get("value")
                for entry in self.rendered[key]["env"]
            }
            self.assertEqual(env["MIGRATIONS_EXPECTED_VERSION"], self.expected)

    def test_wait_for_cnpg_init_container_gates_on_ca_and_postgres(self):
        container = self.rendered["migrations_job"]
        with tempfile.TemporaryDirectory(dir=os.environ.get("TEST_TMPDIR")) as tmp:
            directory = Path(tmp)
            ca_file = directory / "ca.crt"
            ca_file.write_text("synthetic-ca-cert\n", encoding="utf-8")
            psql = directory / "psql"
            psql.write_text(
                f"#!{sys.executable}\n"
                "import os, sys\n"
                "if os.environ.get('FAKE_PSQL_FAIL') == '1':\n"
                "    sys.exit(1)\n"
                "print('1')\n",
                encoding="utf-8",
            )
            psql.chmod(0o755)
            sleep = directory / "sleep"
            sleep.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            sleep.chmod(0o755)

            base_env = os.environ.copy()
            for entry in container["env"]:
                if "value" in entry:
                    base_env[entry["name"]] = entry["value"]
                else:
                    base_env[entry["name"]] = "synthetic-test-value"
            base_env["PATH"] = str(directory) + os.pathsep + os.defpath
            base_env["CNPG_CA_FILE"] = str(ca_file)

            ok = subprocess.run(
                container["command"] + container["args"],
                env=base_env,
                capture_output=True,
                text=True,
                timeout=60,
            )
            self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
            self.assertIn("CNPG cluster is ready", ok.stdout)

            fail_env = dict(base_env, FAKE_PSQL_FAIL="1")
            failed = subprocess.run(
                container["command"] + container["args"],
                env=fail_env,
                capture_output=True,
                text=True,
                timeout=60,
            )
            self.assertEqual(failed.returncode, 1, failed.stdout + failed.stderr)
            self.assertIn("Timed out waiting for CNPG cluster", failed.stderr)

            missing_ca_env = dict(base_env, CNPG_CA_FILE=str(directory / "missing-ca.crt"))
            missing_ca = subprocess.run(
                container["command"] + container["args"],
                env=missing_ca_env,
                capture_output=True,
                text=True,
                timeout=60,
            )
            self.assertEqual(missing_ca.returncode, 1, missing_ca.stdout + missing_ca.stderr)
            self.assertIn("Waiting for CNPG CA certificate", missing_ca.stdout)

    def run_guard(self, container, applied):
        with tempfile.TemporaryDirectory(dir=os.environ.get("TEST_TMPDIR")) as tmp:
            directory = Path(tmp)
            database = directory / "schema.sqlite"
            with sqlite3.connect(database) as connection:
                if applied is not None:
                    connection.execute("CREATE TABLE schema_migrations (version BIGINT)")
                    connection.executemany(
                        "INSERT INTO schema_migrations VALUES (?)",
                        [(version,) for version in applied],
                    )
            psql = directory / "psql"
            psql.write_text(
                f"#!{sys.executable}\n"
                "import json, os, sqlite3, sys\n"
                "query = sys.argv[sys.argv.index('-tAc') + 1]\n"
                "with open(os.environ['PROBE_LOG'], 'a') as log:\n"
                "    log.write(json.dumps(query) + '\\n')\n"
                "with sqlite3.connect(':memory:') as db:\n"
                "    db.execute('ATTACH DATABASE ? AS platform', (os.environ['PROBE_DATABASE'],))\n"
                "    for row in db.execute(query):\n"
                "        print('|'.join(('t' if cell else 'f') if index == 1 else str(cell)\n"
                "                       for index, cell in enumerate(row)))\n",
                encoding="utf-8",
            )
            psql.chmod(0o755)
            sleep = directory / "sleep"
            sleep.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            sleep.chmod(0o755)
            env = os.environ.copy()
            for entry in container["env"]:
                if "value" in entry:
                    env[entry["name"]] = entry["value"]
                else:
                    env[entry["name"]] = "synthetic-test-value"
            env.update(
                PATH=str(directory) + os.pathsep + os.defpath,
                PROBE_DATABASE=str(database),
                PROBE_LOG=str(directory / "queries.jsonl"),
            )
            result = subprocess.run(
                container["command"] + container["args"],
                env=env,
                capture_output=True,
                text=True,
                timeout=60,
            )
            self.assertTrue(
                (directory / "queries.jsonl").is_file(),
                result.stdout + result.stderr,
            )
            return result

    def test_rendered_guard_exit_status(self):
        newest = int(newest_migration_version())
        cases = (
            ("default", [newest - 1], 1, "schema is stale"),
            ("default", [newest - 1, newest], 0, "Migrations current"),
            ("default", [newest + 1], 0, "Migrations current"),
            ("default", [], 1, "schema is stale"),
            ("default", None, 1, "schema_migrations unreadable"),
            ("empty", [1], 0, "Migrations current"),
            ("empty", [], 0, "Migrations current"),
            ("empty", None, 1, "schema_migrations unreadable"),
        )
        empty_env = {
            entry["name"]: entry.get("value")
            for entry in self.rendered["empty"]["env"]
        }
        self.assertEqual(empty_env["MIGRATIONS_EXPECTED_VERSION"], "")
        for name, applied, status, message in cases:
            with self.subTest(expected=name, applied=applied):
                result = self.run_guard(self.rendered[name], applied)
                output = result.stdout + result.stderr
                self.assertEqual(result.returncode, status, output)
                self.assertIn(message, output)
                if message == "schema is stale":
                    self.assertIn("--no-hooks", result.stderr)
                    self.assertIn(f"expected={newest}", result.stderr)


if __name__ == "__main__":
    unittest.main()
