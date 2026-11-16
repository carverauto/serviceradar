# Copyright 2026 Carver Automation Corporation.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Keeps the committed schema baseline from drifting too far behind the migrations on disk.

`elixir/serviceradar_core/priv/repo/baseline/platform_schema.sql` is what a fresh database is
built from, and `metadata.json` records the last migration version it contains
(`included_through`). Everything newer is replayed on top.

Nothing detected staleness before this gate. The only consumer of `included_through` and
`schema_sha256` was `startup_migrations.ex`, and there was no schema-diff or freshness check
anywhere in the build graph -- so the baseline sat 118 migrations behind with nothing to say so.

That was survivable while only service startup used the baseline, because the `:migrated` branch
applies the newer migrations on top and converges. It stops being survivable now that the CI
fixture template and the developer migrate task bootstrap from it too: a stale baseline then
shapes the schema every test runs against, and the replay it was introduced to avoid grows back
one migration at a time.

This gate is deliberately a DRIFT check, not schema-diff validation. It answers "is the baseline
too far behind?" and nothing else. It does NOT prove the baseline reproduces the schema a full
migration replay would produce -- `refactor-fresh-install-db-bootstrap` specifies that as
"Baseline matches migration replay" and it is still unimplemented. Do not read a green run here
as satisfying that requirement.

Also verifies the checksum, because a baseline whose `schema_sha256` no longer matches its own
SQL file fails closed at startup (`verify_baseline_checksum!`) -- a failure worth catching in CI
rather than on a first boot.
"""

import hashlib
import json
import os
import pathlib
import re
import unittest

# How far behind the baseline may fall before this fails. Chosen to be generous: the point is to
# catch a baseline that has been forgotten for a release cycle, not to demand a refresh for every
# migration. Lower it if replay time creeps back up.
MAX_MIGRATIONS_BEHIND = 150

CORE = pathlib.Path("elixir/serviceradar_core")
BASELINE_DIR = CORE / "priv/repo/baseline"
METADATA = BASELINE_DIR / "metadata.json"
MIGRATIONS = CORE / "priv/repo/migrations"

VERSION_RE = re.compile(r"^(\d+)_")


def _runfiles_root() -> pathlib.Path:
    # Bazel runs tests from the runfiles tree; a direct `python3` run uses the workspace root.
    for env in ("TEST_SRCDIR",):
        root = os.environ.get(env)
        if root:
            workspace = os.environ.get("TEST_WORKSPACE", "")
            candidate = pathlib.Path(root) / workspace if workspace else pathlib.Path(root)
            if (candidate / METADATA).exists():
                return candidate
    return pathlib.Path.cwd()


ROOT = _runfiles_root()

# Section headers build/schema_baseline/generate_baseline.py writes. A baseline without them was
# produced by a generator that drops the state they carry.
SEED_DATA_MARKER = "-- ServiceRadar: seed data left by the migrations."
POLICY_MARKER = "-- ServiceRadar: restore TimescaleDB compression and retention."

# Tables a covered migration inserts literal rows into that the baseline deliberately does not
# carry, each with the reason. Keep this short: every entry is a table a fresh install and an
# upgraded install disagree about.
SEED_EXEMPTIONS = {
    "oban_jobs": "jobs a migration enqueues process rows an existing database holds; "
    "a database the baseline creates holds none",
}

# `INSERT INTO` followed by an optionally schema-qualified table. A table named by interpolation
# (`device_inventory_#{dimension}_counts`) is captured with its `#` and then skipped.
INSERT_RE = re.compile(
    r"INSERT\s+INTO\s+(?:#\{[^}]*\}\.|\"?platform\"?\.)?\"?([a-z_][a-z0-9_#{}@]*)",
    re.IGNORECASE,
)
# Code that only a trigger body can run, assembled outside a dollar-quoted string.
TRIGGER_ONLY_RE = re.compile(r"\b(?:NEW|OLD)\.|\bTG_[A-Z]+\b", re.IGNORECASE)
DOLLAR_QUOTE_RE = re.compile(r"\$([A-Za-z_]*)\$")
POLICY_CALL_RE = re.compile(
    r"\b(?:add_retention_policy|add_compression_policy)\s*\(|timescaledb\.compress\b"
)


def strip_function_bodies(text: str) -> str:
    """Drop dollar-quoted bodies except `DO` blocks.

    A function or trigger body runs later, against rows that exist then; only a `DO` block runs
    while the migration itself does.
    """
    out: list[str] = []
    pos = 0
    while (match := DOLLAR_QUOTE_RE.search(text, pos)) is not None:
        end = text.find(match.group(0), match.end())
        if end < 0:
            break
        is_do_block = re.search(r"\bDO\s*$", text[: match.start()], re.IGNORECASE) is not None
        out.append(text[pos : match.start()])
        out.append(text[match.start() : end + len(match.group(0))] if is_do_block else " ")
        pos = end + len(match.group(0))
    out.append(text[pos:])
    return "".join(out)


def _statement_tail(text: str, start: int) -> str:
    ends = [i for i in (text.find(";", start), text.find('"""', start)) if i >= 0]
    return text[start : min(ends) if ends else len(text)]


def _selects_from_rows(tail: str) -> bool:
    """Whether the outermost SELECT reads rows (has its own FROM), at parenthesis depth 0."""
    select = re.search(r"\bSELECT\b", tail, re.IGNORECASE)
    if select is None:
        return False
    depth = 0
    for match in re.finditer(r"\(|\)|\b(FROM|WHERE|ON\s+CONFLICT)\b", tail[select.end() :], re.I):
        token = match.group(0)
        if token == "(":
            depth += 1
        elif token == ")":
            depth -= 1
        elif depth == 0:
            return token.upper() == "FROM"
    return False


def literal_seed_tables(text: str) -> set[str]:
    """Tables a migration inserts literal rows into when it runs.

    `INSERT ... VALUES`, `DEFAULT VALUES`, and an `INSERT ... SELECT` whose outer SELECT reads no
    table count; an `INSERT ... SELECT ... FROM` copies existing rows and inserts nothing into an
    empty database. Rows written by function and trigger bodies do not count either.
    """
    text = strip_function_bodies(text)
    tables = set()
    for match in INSERT_RE.finditer(text):
        if "#" in match.group(1):
            continue
        tail = _statement_tail(text, match.end())
        if TRIGGER_ONLY_RE.search(tail):
            continue
        values = re.search(r"\bVALUES\b", tail, re.IGNORECASE)
        select = re.search(r"\bSELECT\b", tail, re.IGNORECASE)
        if values and (select is None or values.start() < select.start()):
            tables.add(match.group(1).lower())
        elif select and not _selects_from_rows(tail):
            tables.add(match.group(1).lower())
    return tables


def baseline_seed_tables(schema_sql: str) -> set[str]:
    _, marker, section = schema_sql.partition(SEED_DATA_MARKER)
    if not marker:
        return set()
    return {m.lower() for m in re.findall(r"^INSERT INTO platform\.\"?(\w+)\"? ", section, re.MULTILINE)}


def migration_versions() -> list[int]:
    versions = []
    for path in sorted((ROOT / MIGRATIONS).glob("*.exs")):
        match = VERSION_RE.match(path.name)
        if match:
            versions.append(int(match.group(1)))
    return sorted(versions)


class SchemaBaselineFreshnessTest(unittest.TestCase):
    def setUp(self) -> None:
        metadata_path = ROOT / METADATA
        self.assertTrue(
            metadata_path.exists(),
            f"schema baseline metadata missing at {metadata_path}",
        )
        self.metadata = json.loads(metadata_path.read_text())

    def test_metadata_declares_required_fields(self) -> None:
        for field in ("included_through", "schema_file", "schema_sha256", "version"):
            self.assertIn(
                field,
                self.metadata,
                f"{METADATA} is missing '{field}'; startup reads it and will fail closed",
            )

    def test_checksum_matches_the_committed_schema_file(self) -> None:
        schema_file = ROOT / BASELINE_DIR / self.metadata["schema_file"]
        self.assertTrue(schema_file.exists(), f"baseline schema file missing: {schema_file}")

        digest = hashlib.sha256(schema_file.read_bytes()).hexdigest()
        self.assertEqual(
            digest,
            self.metadata["schema_sha256"],
            f"\n{schema_file} does not match the schema_sha256 in {METADATA}.\n"
            "Startup verifies this and refuses to bootstrap when it disagrees.\n"
            "Regenerate the baseline, or correct schema_sha256 if the SQL is intentional.",
        )

    def test_baseline_omits_timescaledb_compressed_chunk_tables(self) -> None:
        # TimescaleDB names a hypertable's compressed table from its own catalog when
        # compression is enabled. A pg_dump'd copy left in the baseline is an empty plain
        # table that a later compression migration collides with (42P07) once the set of
        # hypertables, and so the numbering, changes.
        schema_file = ROOT / BASELINE_DIR / self.metadata["schema_file"]
        leftovers = re.findall(
            r"^CREATE TABLE _timescaledb_internal\.(_compressed_hypertable_\d+) ",
            schema_file.read_text(),
            re.MULTILINE,
        )
        self.assertEqual(
            leftovers,
            [],
            f"\n{schema_file} creates TimescaleDB compressed-chunk tables {leftovers}.\n"
            "build/schema_baseline/generate_baseline.py must exclude them from pg_dump.",
        )

    def test_baseline_is_not_too_far_behind_the_migrations_on_disk(self) -> None:
        versions = migration_versions()
        self.assertTrue(versions, f"no migrations found under {MIGRATIONS}")

        included_through = int(self.metadata["included_through"])
        behind = [v for v in versions if v > included_through]

        self.assertLessEqual(
            len(behind),
            MAX_MIGRATIONS_BEHIND,
            f"\nThe schema baseline is {len(behind)} migrations behind (limit "
            f"{MAX_MIGRATIONS_BEHIND}).\n"
            f"  included_through : {included_through}\n"
            f"  newest on disk   : {versions[-1]}\n"
            f"  total on disk    : {len(versions)}\n\n"
            "Every fresh database replays those on top of the baseline, so this is the replay\n"
            "cost growing back. Regenerate the baseline from a migration-replayed empty\n"
            "database and update included_through + schema_sha256 in\n"
            f"{METADATA}.\n",
        )

    def test_included_through_is_an_actual_migration_version(self) -> None:
        versions = migration_versions()
        included_through = int(self.metadata["included_through"])

        self.assertIn(
            included_through,
            versions,
            f"\nincluded_through={included_through} does not match any migration on disk.\n"
            "It should name the last migration the baseline contains. A value that names no\n"
            "migration means the baseline was generated against a different tree, and the\n"
            "boundary between 'contained' and 'replayed' is guesswork.",
        )


class SchemaBaselineReproducesReplayTest(unittest.TestCase):
    """A database created from the baseline must hold what a full replay leaves behind.

    The baseline records every covered migration as applied, so a migration that seeds rows or
    installs TimescaleDB policies never runs on a fresh install; what it did has to be in the
    baseline. `build/schema_baseline/generate_baseline.py` captures both from the replayed
    database it dumps. These checks fail when a baseline lacks them, from a migration's source
    alone; `database_bootstrap_integration_test.exs` compares the policy state of a database
    actually built from the baseline against a replayed one.
    """

    def setUp(self) -> None:
        self.metadata = json.loads((ROOT / METADATA).read_text())
        self.schema_sql = (ROOT / BASELINE_DIR / self.metadata["schema_file"]).read_text()
        through = int(self.metadata["included_through"])
        self.covered = [
            path
            for path in sorted((ROOT / MIGRATIONS).glob("*.exs"))
            if (m := VERSION_RE.match(path.name)) and int(m.group(1)) <= through
        ]

    def test_every_covered_seed_is_in_the_baseline(self) -> None:
        carried = baseline_seed_tables(self.schema_sql)
        missing = sorted(
            f"{table} (seeded by {path.name})"
            for path in self.covered
            for table in literal_seed_tables(path.read_text())
            if table not in carried and table not in SEED_EXEMPTIONS
        )
        self.assertEqual(
            missing,
            [],
            "\nThese tables get rows from a migration the baseline records as applied, and the "
            "baseline carries none, so a fresh install never has them:\n  "
            + "\n  ".join(missing)
            + "\n\nRegenerate the baseline with `bazel run //build/schema_baseline:generate`, "
            "which captures seed rows from the replayed database. If a table is meant to start "
            "empty on a fresh install, add it to SEED_EXEMPTIONS with the reason.",
        )

    def test_covered_timescaledb_policies_are_in_the_baseline(self) -> None:
        callers = [p.name for p in self.covered if POLICY_CALL_RE.search(p.read_text())]
        if not callers:
            self.skipTest("no covered migration configures compression or retention")
        # assertTrue, not assertIn: assertIn would print the whole multi-megabyte baseline.
        self.assertTrue(
            POLICY_MARKER in self.schema_sql,
            f"\n{len(callers)} covered migrations configure TimescaleDB compression or retention "
            f"(for example {callers[0]}), but the baseline restores none of it. Regenerate it with "
            "`bazel run //build/schema_baseline:generate`.",
        )


class SeedScannerTest(unittest.TestCase):
    """The migration scanner above, on invented migration text."""

    def test_literal_rows_count_and_copies_do_not(self) -> None:
        source = '''
        execute("INSERT INTO #{@prefix}.widget_settings DEFAULT VALUES")
        execute("""
        INSERT INTO platform.widget_rules (name) VALUES ('a'), ('b')
        """)
        execute("""
        INSERT INTO platform.widget_profiles (name)
        SELECT 'Default' WHERE NOT EXISTS (SELECT 1 FROM platform.widget_profiles)
        """)
        execute("INSERT INTO platform.widget_archive (id) SELECT id FROM platform.widgets")
        execute("INSERT INTO platform.widget_#{kind}_counts (key) VALUES ('total')")
        '''
        self.assertEqual(
            literal_seed_tables(source),
            {"widget_settings", "widget_rules", "widget_profiles"},
        )

    def test_function_bodies_do_not_count_but_do_blocks_do(self) -> None:
        source = '''
        execute("""
        CREATE FUNCTION platform.widget_trigger() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          INSERT INTO platform.widget_log (id) VALUES (NEW.id);
          RETURN NEW;
        END
        $$
        """)
        @log_insert """
        INSERT INTO #{@prefix}.widget_audit (id) VALUES (NEW.id);
        """
        execute("""
        DO $$
        BEGIN
          INSERT INTO platform.widget_defaults (name) VALUES ('x');
        END
        $$
        """)
        '''
        self.assertEqual(literal_seed_tables(source), {"widget_defaults"})


if __name__ == "__main__":
    unittest.main(verbosity=2)
