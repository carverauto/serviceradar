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
