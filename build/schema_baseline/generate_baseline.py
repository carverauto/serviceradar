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

"""Generate the committed schema baseline from a migration-replayed database.

    DATABASE_URL=postgres://... bazel run //build/schema_baseline:generate

`DATABASE_URL` must point at an otherwise empty database that migrations were replayed into
(`mix serviceradar.db.migrate --no-baseline`; to stop at an earlier version, create the
`platform` schema first so the ledger lands there, then `mix ecto.migrate --to <version>`). The
newest version in its `platform.schema_migrations` ledger becomes `included_through`.

A database created from the baseline must end up where a full replay ends up. `pg_dump
--schema-only` captures only part of that, so the baseline is the dump plus four sections
generated from the same database's catalogs:

1. TimescaleDB hypertable registration (schema-only dumps leave plain tables).
2. Continuous aggregates and their refresh policies (likewise left as plain views).
3. Compression settings, compression policies and retention policies.
4. Seed data: every row the migrations left in an application table.

The first two sections are what the retired `scripts/db/generate-platform-baseline.sh` emitted,
byte for byte. Anything in the catalog this tool does not know how to
reproduce (a job type, a compressed continuous aggregate, a sparse compression index) stops it,
because a baseline that silently omits state is the defect it exists to prevent.

`pg_dump` and `psql` come from PATH, or from `PG_DUMP` / `PSQL`; `pg_dump` must be PostgreSQL
18, the major version the baseline metadata records.
"""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

POSTGRES_MAJOR = 18
BASELINE_RELATIVE = pathlib.Path("elixir/serviceradar_core/priv/repo/baseline")
MIGRATIONS_RELATIVE = pathlib.Path("elixir/serviceradar_core/priv/repo/migrations")
SCHEMA_FILE = "platform_schema.sql"
METADATA_FILE = "metadata.json"

SEED_DATA_MARKER = "-- ServiceRadar: seed data left by the migrations."
POLICY_MARKER = "-- ServiceRadar: restore TimescaleDB compression and retention."

# Tables whose rows are not seed data. The migration ledgers and the baseline record are
# written by the bootstrap itself. Oban jobs that migrations enqueue are upgrade work over rows
# an existing database already holds; a database the baseline creates holds none.
SEED_DATA_EXCLUDED_TABLES = (
    "schema_migrations",
    "ash_schema_migrations",
    "serviceradar_schema_baselines",
    "oban_jobs",
    "oban_peers",
    "oban_producers",
)

# TimescaleDB creates these jobs itself, for every database that loads the extension.
EXTENSION_OWNED_JOBS = ("policy_telemetry", "policy_job_stat_history_retention")
REPRODUCED_JOBS = (
    "policy_refresh_continuous_aggregate",
    "policy_compression",
    "policy_retention",
)


class GenerationError(RuntimeError):
    pass


# -- database access ---------------------------------------------------------------------------


def _binary(env_name: str, default: str) -> str:
    return os.environ.get(env_name) or default


def psql(url: str, sql: str) -> str:
    """Run `sql` and return psql's unaligned, tuples-only output without a trailing newline."""
    result = subprocess.run(
        [_binary("PSQL", "psql"), "-w", url, "-v", "ON_ERROR_STOP=1", "-q", "-X", "-t", "-A", "-f", "-"],
        input=sql,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise GenerationError(f"psql failed:\n{result.stderr}")
    return result.stdout.rstrip("\n")


def check_pg_dump_major() -> None:
    output = subprocess.run(
        [_binary("PG_DUMP", "pg_dump"), "--version"], capture_output=True, text=True, check=True
    ).stdout
    match = re.search(r"\b(\d+)(?:\.\d+)+", output)
    if not match or int(match.group(1)) != POSTGRES_MAJOR:
        raise GenerationError(
            f"pg_dump must be PostgreSQL {POSTGRES_MAJOR} (got {output.strip()!r}); "
            "set PG_DUMP to a matching binary"
        )


def pg_dump_schema(url: str) -> str:
    with tempfile.TemporaryDirectory() as tmp:
        out = pathlib.Path(tmp) / "schema.sql"
        # TimescaleDB's internal compressed-chunk tables are not schema the baseline owns:
        # TimescaleDB creates `_compressed_hypertable_<id>` itself whenever compression is
        # enabled, numbering it from its own catalog. pg_dump emits them as plain, empty tables,
        # and on a database bootstrapped from the baseline those leftovers occupy names
        # TimescaleDB later picks for real compressed tables (42P07 duplicate_table). Leave
        # them out; the compression section below recreates them through the extension.
        subprocess.run(
            [
                _binary("PG_DUMP", "pg_dump"),
                url,
                "--schema-only",
                "--no-owner",
                "--no-privileges",
                "--exclude-table=_timescaledb_internal._compressed_hypertable_*",
                f"--file={out}",
            ],
            check=True,
        )
        return out.read_text()


# -- sections ----------------------------------------------------------------------------------


def normalize_schema_dump(dump: str) -> str:
    for schema in ("platform", "ag_catalog", "platform_graph"):
        dump = dump.replace(f"CREATE SCHEMA {schema};", f"CREATE SCHEMA IF NOT EXISTS {schema};")
    return dump.rstrip("\n") + "\n"


TIMESCALEDB_SCHEMA_SQL = (
    "(SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace "
    "WHERE e.extname = 'timescaledb')"
)

HYPERTABLE_SQL = f"""
SELECT format(
  'SELECT %I.create_hypertable(%L, %L, chunk_time_interval => %L::interval, migrate_data => true, if_not_exists => true);',
  {TIMESCALEDB_SCHEMA_SQL},
  h.hypertable_schema || '.' || h.hypertable_name,
  d.column_name,
  d.time_interval::text
)
FROM timescaledb_information.hypertables h
JOIN timescaledb_information.dimensions d
  ON d.hypertable_schema = h.hypertable_schema AND d.hypertable_name = h.hypertable_name
  AND d.dimension_number = 1
ORDER BY h.hypertable_name
"""

# pg_dump already emitted every cagg's outer name as a plain CREATE VIEW and its three internal
# objects (the materialization table plus the `_direct_view_NN`/`_partial_view_NN` pair) as
# plain CREATE TABLE/CREATE VIEW. Drop every such orphaned set BEFORE creating any real
# continuous aggregate: TimescaleDB names each new materialization table in creation order, which
# does not match the source database's numbering, so an orphan of a later cagg can collide with
# the name TimescaleDB picks for an earlier one.
CAGG_DROPS_SQL = """
SELECT format(
  'DROP VIEW IF EXISTS %I.%I CASCADE; DROP VIEW IF EXISTS %I.%I CASCADE; DROP VIEW IF EXISTS %I.%I CASCADE; DROP TABLE IF EXISTS %I.%I CASCADE;',
  view_schema, view_name,
  materialization_hypertable_schema, regexp_replace(materialization_hypertable_name, '_materialized_hypertable_', '_direct_view_'),
  materialization_hypertable_schema, regexp_replace(materialization_hypertable_name, '_materialized_hypertable_', '_partial_view_'),
  materialization_hypertable_schema, materialization_hypertable_name
)
FROM timescaledb_information.continuous_aggregates
ORDER BY view_name
"""

# No IF NOT EXISTS: TimescaleDB's continuous-aggregate DDL hook silently falls back to a plain,
# unregistered view when it is present. This only ever runs into a fresh, empty database.
CAGG_CREATES_SQL = r"""
WITH RECURSIVE cagg_depth AS (
  SELECT c.view_schema, c.view_name, c.hypertable_schema, c.hypertable_name,
         c.materialization_hypertable_schema, c.materialization_hypertable_name,
         c.view_definition, 0 AS depth
  FROM timescaledb_information.continuous_aggregates c
  WHERE c.hypertable_schema <> '_timescaledb_internal'
  UNION ALL
  SELECT c.view_schema, c.view_name, c.hypertable_schema, c.hypertable_name,
         c.materialization_hypertable_schema, c.materialization_hypertable_name,
         c.view_definition, cd.depth + 1
  FROM timescaledb_information.continuous_aggregates c
  JOIN cagg_depth cd
    ON c.hypertable_schema = cd.materialization_hypertable_schema
   AND c.hypertable_name = cd.materialization_hypertable_name
)
SELECT format(
  'CREATE MATERIALIZED VIEW %I.%I WITH (timescaledb.continuous) AS %s WITH NO DATA;',
  view_schema, view_name, regexp_replace(view_definition, ';\s*$', '')
)
FROM cagg_depth
ORDER BY depth, view_name
"""

CAGG_REFRESH_POLICIES_SQL = """
SELECT format(
  'SELECT add_continuous_aggregate_policy(%L, start_offset => %L::interval, end_offset => %L::interval, schedule_interval => %L::interval, if_not_exists => true);',
  c.view_schema || '.' || c.view_name,
  j.config->>'start_offset',
  j.config->>'end_offset',
  j.schedule_interval::text
)
FROM timescaledb_information.continuous_aggregates c
JOIN timescaledb_information.jobs j
  ON j.hypertable_schema = c.view_schema AND j.hypertable_name = c.view_name
WHERE j.proc_name = 'policy_refresh_continuous_aggregate'
ORDER BY c.view_name
"""

UNSUPPORTED_TIMESCALEDB_STATE_SQL = f"""
SELECT 'job ' || proc_schema || '.' || proc_name || ' on ' || coalesce(hypertable_name, '(none)')
FROM timescaledb_information.jobs
WHERE proc_name NOT IN ({", ".join(f"'{p}'" for p in EXTENSION_OWNED_JOBS + REPRODUCED_JOBS)})
UNION ALL
SELECT 'compression on continuous aggregate ' || view_name
FROM timescaledb_information.continuous_aggregates
WHERE compression_enabled
UNION ALL
SELECT 'compression option on ' || hypertable::text || ': '
       || concat_ws(', ',
            CASE WHEN index IS NOT NULL THEN 'index=' || index::text END,
            CASE WHEN compress_interval_length IS NOT NULL
                 THEN 'compress_interval_length=' || compress_interval_length END)
FROM timescaledb_information.hypertable_compression_settings
WHERE index IS NOT NULL OR compress_interval_length IS NOT NULL
UNION ALL
SELECT 'policy option on ' || coalesce(hypertable_name, '(none)') || ': ' || key
FROM timescaledb_information.jobs, jsonb_object_keys(config) AS key
WHERE (proc_name = 'policy_compression' AND key NOT IN ('hypertable_id', 'compress_after'))
   OR (proc_name = 'policy_retention' AND key NOT IN ('hypertable_id', 'drop_after'))
ORDER BY 1
"""

COMPRESSION_SETTINGS_SQL = """
SELECT format(
  'ALTER TABLE %I.%I SET (timescaledb.compress, timescaledb.compress_segmentby = %L, timescaledb.compress_orderby = %L);',
  h.hypertable_schema,
  h.hypertable_name,
  coalesce(s.segmentby, ''),
  coalesce(s.orderby, '')
)
FROM timescaledb_information.hypertable_compression_settings s
JOIN timescaledb_information.hypertables h
  ON format('%I.%I', h.hypertable_schema, h.hypertable_name)::regclass = s.hypertable
WHERE h.compression_enabled
ORDER BY h.hypertable_name
"""

POLICY_JOBS_SQL = f"""
SELECT format(
  CASE j.proc_name
    WHEN 'policy_compression' THEN
      'SELECT %I.add_compression_policy(%L, compress_after => %L::interval, schedule_interval => %L::interval, if_not_exists => true);'
    ELSE
      'SELECT %I.add_retention_policy(%L, drop_after => %L::interval, schedule_interval => %L::interval, if_not_exists => true);'
  END,
  {TIMESCALEDB_SCHEMA_SQL},
  j.hypertable_schema || '.' || j.hypertable_name,
  coalesce(j.config->>'compress_after', j.config->>'drop_after'),
  j.schedule_interval::text
)
FROM timescaledb_information.jobs j
WHERE j.proc_name IN ('policy_compression', 'policy_retention')
ORDER BY j.proc_name, j.hypertable_name
"""

# One INSERT per row, in foreign-key order. Values that belong to the moment of installation are
# not copied from the replay: columns whose default is not immutable (ids from gen_random_uuid()
# or a sequence, now() timestamps, a dictionary epoch) are left out so the default runs, and a
# timestamp a migration set to the time it ran (a watermark, `inserted_at`) is written as now().
# A timestamp counts as such when it falls after the replay began, less a day of margin.
# Generated and identity columns are left out because the database computes them. User
# triggers are disabled around each table's rows: whatever a trigger wrote during the replay is
# already captured as rows of its own table, and firing it again would write it twice.
SEED_DATA_SQL = f"""
CREATE FUNCTION pg_temp.baseline_seed_tables()
RETURNS TABLE (rel oid, schema_name name, table_name name, fk_depth integer)
LANGUAGE sql AS $fn$
  WITH RECURSIVE candidates AS (
    SELECT c.oid, n.nspname, c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'platform'
      AND c.relkind IN ('r', 'p')
      AND NOT c.relispartition
      AND c.relname NOT IN ({", ".join(f"'{t}'" for t in SEED_DATA_EXCLUDED_TABLES)})
      AND NOT EXISTS (
        SELECT 1 FROM pg_depend d
        WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e'
      )
  ),
  depth AS (
    SELECT oid, 0 AS d FROM candidates
    UNION ALL
    SELECT con.conrelid, depth.d + 1
    FROM depth
    JOIN pg_constraint con
      ON con.contype = 'f' AND con.confrelid = depth.oid AND con.conrelid <> con.confrelid
    JOIN candidates ON candidates.oid = con.conrelid
    WHERE depth.d < 32
  )
  SELECT candidates.oid, nspname, relname, max(depth.d)
  FROM candidates JOIN depth USING (oid)
  GROUP BY candidates.oid, nspname, relname
$fn$;

CREATE FUNCTION pg_temp.baseline_seed_columns(rel oid)
RETURNS text[]
LANGUAGE sql AS $fn$
  SELECT array_agg(a.attname::text ORDER BY a.attnum)
  FROM pg_attribute a
  LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
  WHERE a.attrelid = rel
    AND a.attnum > 0
    AND NOT a.attisdropped
    AND a.attgenerated = ''
    AND a.attidentity = ''
    AND NOT (
      ad.oid IS NOT NULL AND (
        ad.adbin::text LIKE '%SQLVALUEFUNCTION%'
        OR EXISTS (
          SELECT 1
          FROM regexp_matches(ad.adbin::text, ':(?:funcid|opfuncid) (\\d+)', 'g') AS m(f)
          JOIN pg_proc p ON p.oid = m.f[1]::oid
          WHERE p.provolatile <> 'i'
        )
      )
    )
$fn$;

CREATE FUNCTION pg_temp.baseline_seed_statements()
RETURNS SETOF text
LANGUAGE plpgsql AS $fn$
DECLARE
  t record;
  cols text[];
  has_rows boolean;
  qualified text;
  -- schema_migrations.inserted_at is written in UTC as each migration runs.
  replay_began timestamp := (SELECT min(inserted_at) FROM platform.schema_migrations) - interval '1 day';
BEGIN
  FOR t IN
    SELECT * FROM pg_temp.baseline_seed_tables() ORDER BY fk_depth, schema_name, table_name
  LOOP
    qualified := format('%I.%I', t.schema_name, t.table_name);
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM %s)', qualified) INTO has_rows;
    CONTINUE WHEN NOT has_rows;

    cols := pg_temp.baseline_seed_columns(t.rel);
    RETURN NEXT format('ALTER TABLE %s DISABLE TRIGGER USER;', qualified);
    RETURN QUERY EXECUTE format(
      'SELECT stmt FROM (SELECT %L || concat_ws(%L, %s) || %L AS stmt FROM %s AS t) AS s ORDER BY stmt',
      format('INSERT INTO %s (%s) VALUES (', qualified,
             (SELECT string_agg(quote_ident(c), ', ') FROM unnest(cols) AS c)),
      ', ',
      (SELECT string_agg(
         CASE a.atttypid
           WHEN 'timestamp'::regtype THEN format(
             'CASE WHEN t.%I >= %L::timestamp THEN %L ELSE quote_nullable(t.%I) END',
             c, replay_began, '(now() AT TIME ZONE ''utc'')', c)
           WHEN 'timestamptz'::regtype THEN format(
             'CASE WHEN t.%I >= (%L::timestamp AT TIME ZONE ''UTC'') THEN %L ELSE quote_nullable(t.%I) END',
             c, replay_began, 'now()', c)
           ELSE format('quote_nullable(t.%I)', c)
         END, ', ' ORDER BY ord)
       FROM unnest(cols) WITH ORDINALITY AS u(c, ord)
       JOIN pg_attribute a ON a.attrelid = t.rel AND a.attname = u.c),
      ');',
      qualified
    );
    RETURN NEXT format('ALTER TABLE %s ENABLE TRIGGER USER;', qualified);
  END LOOP;
END
$fn$;

SELECT * FROM pg_temp.baseline_seed_statements();
"""

# Data outside the `platform` application tables would not be reproduced. Refuse rather than
# ship a baseline that silently drops it.
UNREPRODUCED_DATA_SQL = """
CREATE FUNCTION pg_temp.unreproduced_rows()
RETURNS SETOF text
LANGUAGE plpgsql AS $fn$
DECLARE
  t record;
  has_rows boolean;
BEGIN
  FOR t IN
    SELECT n.nspname, c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
      AND n.nspname = 'platform_graph'
    ORDER BY 1, 2
  LOOP
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.%I)', t.nspname, t.relname) INTO has_rows;
    IF has_rows THEN
      RETURN NEXT format('%I.%I', t.nspname, t.relname);
    END IF;
  END LOOP;
END
$fn$;

SELECT * FROM pg_temp.unreproduced_rows();
"""


def hypertable_section(calls: str) -> str:
    if not calls:
        return ""
    return "\n".join(
        [
            "",
            "--",
            "-- ServiceRadar: restore TimescaleDB hypertable registration.",
            "--",
            "-- pg_dump --schema-only does not capture hypertable catalog state (see",
            "-- comment above). Re-establish it here so a database bootstrapped from",
            "-- this baseline has the same hypertables, on the same time column and",
            "-- chunk interval, as the database this baseline was generated from.",
            "--",
            calls,
            "",
        ]
    )


def cagg_section(drops: str, creates: str, refresh_policies: str) -> str:
    if not creates:
        return ""
    lines = [
        "",
        "--",
        "-- ServiceRadar: restore TimescaleDB continuous aggregates.",
        "--",
        "-- Same gap as hypertables above, for continuous aggregates: schema-only",
        "-- pg_dump does not capture this catalog registration. Recreate each cagg",
        "-- from its own view_definition, then restore its refresh policy, so a",
        "-- database bootstrapped from this baseline has the same continuous",
        "-- aggregates as the database this baseline was generated from.",
        "--",
        "-- view_definition's own table references are unqualified (Postgres omits",
        "-- the schema when the object is on the rendering connection's own",
        "-- search_path), so this block needs platform on search_path -- unlike the",
        "-- rest of this file, which pg_dump already schema-qualifies throughout.",
        "SET search_path = platform, public;",
    ]
    if drops:
        lines.append(drops)
    lines.append(creates)
    if refresh_policies:
        lines += ["", refresh_policies]
    lines += ["", "RESET search_path;", ""]
    return "\n".join(lines)


def policy_section(compression_settings: str, policy_jobs: str) -> str:
    if not compression_settings and not policy_jobs:
        return ""
    lines = [
        "",
        "--",
        POLICY_MARKER,
        "--",
        "-- pg_dump --schema-only captures neither a hypertable's compression settings",
        "-- nor its compression and retention policy jobs. Without this block a",
        "-- database bootstrapped from the baseline stores those hypertables",
        "-- uncompressed and keeps their rows forever.",
        "--",
    ]
    if compression_settings:
        lines.append(compression_settings)
    if policy_jobs:
        lines.append(policy_jobs)
    lines.append("")
    return "\n".join(lines)


def seed_data_section(statements: str) -> str:
    if not statements:
        return ""
    return "\n".join(
        [
            "",
            "--",
            SEED_DATA_MARKER,
            "--",
            "-- A migration that inserts default rows (settings singletons, built-in",
            "-- catalogs, default profiles) is recorded as applied by the baseline and",
            "-- never runs, so its rows are carried here. Columns whose default is not",
            "-- immutable are omitted, so each installation generates its own ids, epochs",
            "-- and timestamps.",
            "--",
            statements,
            "",
        ]
    )


def assemble(schema_dump: str, sections: list[str]) -> str:
    return (normalize_schema_dump(schema_dump) + "".join(sections)).rstrip("\n") + "\n"


def render_metadata(included_through: int, schema_sha256: str) -> str:
    return (
        "{\n"
        '  "version": 1,\n'
        f'  "included_through": {included_through},\n'
        f'  "schema_file": "{SCHEMA_FILE}",\n'
        f'  "schema_sha256": "{schema_sha256}",\n'
        f'  "postgres_major": {POSTGRES_MAJOR},\n'
        '  "generated_from": "migration-replayed empty database"\n'
        "}\n"
    )


def migration_versions(migrations_dir: pathlib.Path) -> list[int]:
    return sorted(int(p.name.split("_", 1)[0]) for p in migrations_dir.glob("*.exs"))


def included_through(ledger: list[int], on_disk: list[int]) -> int:
    """The newest replayed version, after proving the database replayed exactly this tree."""
    if not ledger:
        raise GenerationError("the database records no migrations; replay them first")
    newest = max(ledger)
    expected = [v for v in on_disk if v <= newest]
    if sorted(ledger) != expected:
        missing = sorted(set(expected) - set(ledger))
        extra = sorted(set(ledger) - set(expected))
        raise GenerationError(
            f"the database's migration ledger does not match the migrations on disk through "
            f"{newest}: missing {missing[:10]}, not on disk {extra[:10]}"
        )
    return newest


def generate(url: str, workspace: pathlib.Path) -> pathlib.Path:
    check_pg_dump_major()

    unsupported = psql(url, UNSUPPORTED_TIMESCALEDB_STATE_SQL)
    if unsupported:
        raise GenerationError(
            "TimescaleDB state this generator does not reproduce:\n" + unsupported
        )
    unreproduced = psql(url, UNREPRODUCED_DATA_SQL)
    if unreproduced:
        raise GenerationError("rows outside the platform tables would be lost:\n" + unreproduced)

    # Both ledgers belong in the baseline schema (see SchemaBootstrap.sync_migration_ledgers!/1);
    # a replay run under core's config alone creates only one.
    if psql(url, "SELECT to_regclass('platform.ash_schema_migrations') IS NULL") == "t":
        raise GenerationError(
            "platform.ash_schema_migrations is missing; replay with "
            "`mix serviceradar.db.migrate --no-baseline`, which keeps both migration ledgers"
        )
    ledger = [int(v) for v in psql(url, "SELECT version FROM platform.schema_migrations").split()]
    through = included_through(ledger, migration_versions(workspace / MIGRATIONS_RELATIVE))

    body = assemble(
        pg_dump_schema(url),
        [
            hypertable_section(psql(url, HYPERTABLE_SQL)),
            cagg_section(
                psql(url, CAGG_DROPS_SQL),
                psql(url, CAGG_CREATES_SQL),
                psql(url, CAGG_REFRESH_POLICIES_SQL),
            ),
            policy_section(psql(url, COMPRESSION_SETTINGS_SQL), psql(url, POLICY_JOBS_SQL)),
            seed_data_section(psql(url, SEED_DATA_SQL)),
        ],
    )

    baseline_dir = workspace / BASELINE_RELATIVE
    schema_path = baseline_dir / SCHEMA_FILE
    schema_path.write_text(body)
    sha = hashlib.sha256(body.encode()).hexdigest()
    (baseline_dir / METADATA_FILE).write_text(render_metadata(through, sha))
    return schema_path


def main() -> int:
    url = os.environ.get("DATABASE_URL")
    if not url:
        print("DATABASE_URL must point at a migration-replayed empty database", file=sys.stderr)
        return 2
    workspace = pathlib.Path(os.environ.get("BUILD_WORKSPACE_DIRECTORY") or os.getcwd())
    try:
        schema_path = generate(url, workspace)
    except (GenerationError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        return 1
    print(f"Wrote {schema_path}")
    print(f"Wrote {schema_path.with_name(METADATA_FILE)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
