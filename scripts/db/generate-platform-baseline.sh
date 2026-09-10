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
