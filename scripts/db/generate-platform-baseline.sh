#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASELINE_DIR="${ROOT_DIR}/elixir/serviceradar_core/priv/repo/baseline"
MIGRATIONS_DIR="${ROOT_DIR}/elixir/serviceradar_core/priv/repo/migrations"
SCHEMA_FILE="${BASELINE_DIR}/platform_schema.sql"
METADATA_FILE="${BASELINE_DIR}/metadata.json"

if ! command -v pg_dump >/dev/null 2>&1; then
  echo "pg_dump is required" >&2
  exit 1
fi

if [[ -z "${DATABASE_URL:-}" ]]; then
  echo "DATABASE_URL must point at a fully migrated empty ServiceRadar database" >&2
  exit 1
fi

mkdir -p "${BASELINE_DIR}"

pg_dump "${DATABASE_URL}" \
  --schema-only \
  --no-owner \
  --no-privileges \
  --file="${SCHEMA_FILE}"

tmp_schema="$(mktemp)"
sed \
  -e 's/CREATE SCHEMA platform;/CREATE SCHEMA IF NOT EXISTS platform;/g' \
  -e 's/CREATE SCHEMA ag_catalog;/CREATE SCHEMA IF NOT EXISTS ag_catalog;/g' \
  -e 's/CREATE SCHEMA platform_graph;/CREATE SCHEMA IF NOT EXISTS platform_graph;/g' \
  "${SCHEMA_FILE}" >"${tmp_schema}"
mv "${tmp_schema}" "${SCHEMA_FILE}"
perl -0pi -e 's/\n+\z/\n/' "${SCHEMA_FILE}"

# pg_dump --schema-only captures table structure but not TimescaleDB's own
# hypertable catalog registration (_timescaledb_catalog.hypertable etc). Without
# this, a database bootstrapped from the baseline gets every hypertable back as
# a plain table, silently, for anything whose original conversion migration
# falls before `included_through` -- exactly the class of bug a dedicated
# ensure_*_hypertable repair migration works around for one table at a time,
# until regenerating the baseline folds that migration in and the workaround
# stops running. Capture every currently-registered hypertable here instead, so
# the baseline is self-sufficient and this never has to be fixed per-table again.
hypertable_calls="$(
  psql -w "${DATABASE_URL}" -v ON_ERROR_STOP=1 -q -X -t -A -c "
    SELECT format(
      'SELECT %I.create_hypertable(%L, %L, chunk_time_interval => %L::interval, migrate_data => true, if_not_exists => true);',
      (SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'timescaledb'),
      h.hypertable_schema || '.' || h.hypertable_name,
      d.column_name,
      d.time_interval::text
    )
    FROM timescaledb_information.hypertables h
    JOIN timescaledb_information.dimensions d
      ON d.hypertable_schema = h.hypertable_schema AND d.hypertable_name = h.hypertable_name
      AND d.dimension_number = 1
    ORDER BY h.hypertable_name
  "
)"

if [[ -n "${hypertable_calls}" ]]; then
  {
    echo ""
    echo "--"
    echo "-- ServiceRadar: restore TimescaleDB hypertable registration."
    echo "--"
    echo "-- pg_dump --schema-only does not capture hypertable catalog state (see"
    echo "-- comment above). Re-establish it here so a database bootstrapped from"
    echo "-- this baseline has the same hypertables, on the same time column and"
    echo "-- chunk interval, as the database this baseline was generated from."
    echo "--"
    echo "${hypertable_calls}"
  } >>"${SCHEMA_FILE}"
fi

# Same gap, for continuous aggregates: pg_dump --schema-only does not capture
# TimescaleDB's continuous-aggregate catalog registration either, only (an
# unmarked) materialized view if any at all. Recreate every current cagg from
# its own view_definition, in dependency order (a cagg built on another cagg's
# materialization hypertable, such as flow_traffic_1d on flow_traffic_1h, must
# be created after its dependency), then restore each one's own refresh policy.
# pg_dump already emitted every cagg's outer name as a plain CREATE VIEW
# (relkind reads 'v' for a continuous aggregate's user-facing name, same as
# any other view) and its three internal objects (the materialization table,
# plus the `_direct_view_NN`/`_partial_view_NN` pair TimescaleDB builds
# alongside it) as plain CREATE TABLE/CREATE VIEW -- schema, not catalog
# state, so pg_dump captures all four, just not the registration that makes
# them a continuous aggregate together. Drop every such orphaned set BEFORE
# creating any real continuous aggregate below: TimescaleDB assigns each new
# materialization table's internal name fresh, in creation order, which does
# not match the source database's own numbering, so an orphan belonging to a
# cagg later in the creation order can collide with the fresh name
# TimescaleDB picks for a cagg created earlier.
cagg_drops="$(
  psql -w "${DATABASE_URL}" -v ON_ERROR_STOP=1 -q -X -t -A -c "
    SELECT format(
      'DROP VIEW IF EXISTS %I.%I CASCADE; DROP VIEW IF EXISTS %I.%I CASCADE; DROP VIEW IF EXISTS %I.%I CASCADE; DROP TABLE IF EXISTS %I.%I CASCADE;',
      view_schema, view_name,
      materialization_hypertable_schema, regexp_replace(materialization_hypertable_name, '_materialized_hypertable_', '_direct_view_'),
      materialization_hypertable_schema, regexp_replace(materialization_hypertable_name, '_materialized_hypertable_', '_partial_view_'),
      materialization_hypertable_schema, materialization_hypertable_name
    )
    FROM timescaledb_information.continuous_aggregates
    ORDER BY view_name
  "
)"

cagg_creates="$(
  psql -w "${DATABASE_URL}" -v ON_ERROR_STOP=1 -q -X -t -A -c "
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
    -- No IF NOT EXISTS: TimescaleDB's continuous-aggregate DDL hook does not
    -- handle it -- confirmed empirically that adding it silently falls back
    -- to creating a plain, unregistered view instead of a real continuous
    -- aggregate (no error, no entry in timescaledb_information.continuous_
    -- aggregates). This block only ever runs once, into a fresh empty
    -- database (the orphans above are this same baseline's own pg_dump
    -- output, never anything a real caller could already depend on), so IF
    -- NOT EXISTS was never actually needed here.
    SELECT format(
      'CREATE MATERIALIZED VIEW %I.%I WITH (timescaledb.continuous) AS %s WITH NO DATA;',
      view_schema, view_name, regexp_replace(view_definition, ';\s*\$', '')
    )
    FROM cagg_depth
    ORDER BY depth, view_name
  "
)"

cagg_refresh_policies="$(
  psql -w "${DATABASE_URL}" -v ON_ERROR_STOP=1 -q -X -t -A -c "
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
  "
)"

if [[ -n "${cagg_creates}" ]]; then
  {
    echo ""
    echo "--"
    echo "-- ServiceRadar: restore TimescaleDB continuous aggregates."
    echo "--"
    echo "-- Same gap as hypertables above, for continuous aggregates: schema-only"
    echo "-- pg_dump does not capture this catalog registration. Recreate each cagg"
    echo "-- from its own view_definition, then restore its refresh policy, so a"
    echo "-- database bootstrapped from this baseline has the same continuous"
    echo "-- aggregates as the database this baseline was generated from."
    echo "--"
    echo "-- view_definition's own table references are unqualified (Postgres omits"
    echo "-- the schema when the object is on the rendering connection's own"
    echo "-- search_path), so this block needs platform on search_path -- unlike the"
    echo "-- rest of this file, which pg_dump already schema-qualifies throughout."
    echo "SET search_path = platform, public;"
    if [[ -n "${cagg_drops}" ]]; then
      echo "${cagg_drops}"
    fi
    echo "${cagg_creates}"
    if [[ -n "${cagg_refresh_policies}" ]]; then
      echo ""
      echo "${cagg_refresh_policies}"
    fi
    echo ""
    echo "RESET search_path;"
  } >>"${SCHEMA_FILE}"
fi

schema_sha="$(sha256sum "${SCHEMA_FILE}" | awk '{print $1}')"
included_through="$(
  find "${MIGRATIONS_DIR}" -maxdepth 1 -type f -name '*.exs' -exec basename {} \; |
    sort |
    tail -n 1 |
    sed 's/_.*//'
)"

cat >"${METADATA_FILE}" <<EOF
{
  "version": 1,
  "included_through": ${included_through},
  "schema_file": "platform_schema.sql",
  "schema_sha256": "${schema_sha}",
  "postgres_major": 18,
  "generated_from": "migration-replayed empty database"
}
EOF

echo "Wrote ${SCHEMA_FILE}"
echo "Wrote ${METADATA_FILE}"
