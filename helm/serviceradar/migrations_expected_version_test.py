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
import os
import re
import unittest


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
WEB = CHART_DIR / "templates" / "web.yaml"
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


def declared_expected_version(values: str) -> str:
    # Deliberately a regex over the raw text rather than a YAML parse: the test
    # runs with no third-party deps, and this also pins the key's location under
    # core.migrations rather than accepting it anywhere in the file.
    block = re.search(
        r"\n  migrations:\n(?P<body>(?:    .*\n|\n)+)", values
    )
    if not block:
        raise AssertionError("core.migrations block not found in values.yaml")
    declared = re.search(
        r'^    expectedVersion: "(?P<version>[^"]*)"$',
        block.group("body"),
        re.MULTILINE,
    )
    if not declared:
        raise AssertionError(
            "core.migrations.expectedVersion not found in values.yaml"
        )
    return declared.group("version")


class MigrationsExpectedVersionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.values = VALUES.read_text(encoding="utf-8")
        cls.web = WEB.read_text(encoding="utf-8")

    def test_expected_version_matches_newest_shipped_migration(self):
        newest = newest_migration_version()
        declared = declared_expected_version(self.values)

        self.assertEqual(
            declared,
            newest,
            "helm/serviceradar/values.yaml core.migrations.expectedVersion is stale.\n"
            f"  declared: {declared}\n"
            f"  newest migration: {newest}\n"
            "Set expectedVersion to the newest value. Leaving it behind means the\n"
            "wait-migrations init container will admit a database that is missing\n"
            "the migrations this chart revision ships.",
        )

    def test_init_container_compares_versions_rather_than_existence(self):
        self.assertIn("MIGRATIONS_EXPECTED_VERSION", self.web)
        self.assertIn(
            'value: {{ default "" $migrationVals.expectedVersion | quote }}', self.web
        )
        self.assertIn(
            "COALESCE(MAX(version), 0) >= ${EXPECTED}",
            self.web,
            "the probe must compare the applied high-water mark against the expected"
            " version",
        )
        self.assertNotIn(
            "SELECT 1 FROM platform.schema_migrations LIMIT 1",
            self.web,
            "the existence-only probe is what let a stale schema through; it must not"
            " come back",
        )

    def test_stale_schema_is_a_hard_failure_with_an_actionable_message(self):
        # A stale schema has to fail the init container. Exiting 0 here is the
        # original bug: web-ng starts and the real error surfaces somewhere far
        # less obvious.
        self.assertIn("Schema is behind: applied=${APPLIED}, expected=${EXPECTED}", self.web)
        self.assertIn("Timed out: schema is stale", self.web)
        self.assertIn("--no-hooks", self.web)

    def test_empty_expected_version_falls_back_to_existence_check(self):
        # Operators pinning a schema on purpose can opt out; that path must not
        # interpolate an empty string into the SQL comparison.
        self.assertIn('EXPECTED="${MIGRATIONS_EXPECTED_VERSION:-}"', self.web)
        self.assertIn('if [ -n "${EXPECTED}" ]; then', self.web)
        self.assertIn(
            "SELECT COALESCE(MAX(version), 0), TRUE FROM platform.schema_migrations",
            self.web,
        )


if __name__ == "__main__":
    unittest.main()
