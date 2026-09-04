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


if __name__ == "__main__":
    unittest.main(verbosity=2)
