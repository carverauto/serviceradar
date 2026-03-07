#!/bin/sh
set -eu

DATA_DIR="${CNPG_DATA_DIR:-/var/lib/postgresql/data}"
VERSION_FILE="${DATA_DIR}/PG_VERSION"
EXPECTED_MAJOR="${CNPG_EXPECTED_PG_MAJOR:-18}"

if [ ! -f "$VERSION_FILE" ]; then
  exec "$@"
fi

actual_version="$(tr -d '\r\n' < "$VERSION_FILE")"
actual_major="${actual_version%%.*}"

if [ "$actual_major" != "$EXPECTED_MAJOR" ]; then
  echo "CNPG data volume version mismatch: found PostgreSQL ${actual_version}, expected PostgreSQL ${EXPECTED_MAJOR}." >&2
  echo "Docker Compose does not perform Postgres major upgrades automatically." >&2
  echo "Migrate the existing CNPG data volume to PostgreSQL ${EXPECTED_MAJOR} before starting this stack." >&2
  exit 42
fi

exec "$@"
