#!/bin/sh
set -eu

CERT_DIR="${CNPG_CERT_DIR:-/etc/serviceradar/certs}"
CRED_DIR="${CNPG_CRED_DIR:-/etc/serviceradar/cnpg}"
HOST="${CNPG_HOST:-cnpg}"
PORT="${CNPG_PORT:-5432}"
ADMIN_DB="${CNPG_ADMIN_DATABASE:-postgres}"
APP_DB="${CNPG_DATABASE:-serviceradar}"
APP_USER="${CNPG_APP_USER:-serviceradar}"
TMP_KEY="/tmp/db-superuser-key.pem"

read_trimmed_file() {
  tr -d '\r\n' < "$1"
}

ADMIN_USER="$(read_trimmed_file "${CRED_DIR}/superuser-username")"
ADMIN_PASSWORD="$(read_trimmed_file "${CRED_DIR}/superuser-password")"
APP_PASSWORD="$(read_trimmed_file "${CRED_DIR}/serviceradar-password")"

cp "${CERT_DIR}/db-superuser-key.pem" "${TMP_KEY}"
chmod 600 "${TMP_KEY}"

export PGHOST="${HOST}"
export PGPORT="${PORT}"
export PGDATABASE="${ADMIN_DB}"
export PGUSER="${ADMIN_USER}"
export PGPASSWORD="${ADMIN_PASSWORD}"
export PGSSLMODE="${CNPG_SSL_MODE:-verify-full}"
export PGSSLROOTCERT="${CERT_DIR}/root.pem"
export PGSSLCERT="${CERT_DIR}/db-superuser.pem"
export PGSSLKEY="${TMP_KEY}"

psql -v ON_ERROR_STOP=1 -c "SELECT 1" >/dev/null

# PG18 on newer glibc can inherit stale collation metadata from older clusters.
# Refresh what we can, but continue even if the server reports no change is needed.
psql -v ON_ERROR_STOP=1 -c "ALTER DATABASE postgres REFRESH COLLATION VERSION" >/dev/null 2>&1 || true
psql -v ON_ERROR_STOP=1 -c "ALTER DATABASE template1 REFRESH COLLATION VERSION" >/dev/null 2>&1 || true

psql -v ON_ERROR_STOP=1 \
  -v app_user="${APP_USER}" \
  -v app_password="${APP_PASSWORD}" <<'SQL'
SELECT CASE
  WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user')
    THEN format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'app_user', :'app_password')
  ELSE format('CREATE ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password')
END \gexec
SQL

psql -v ON_ERROR_STOP=1 \
  -v app_db="${APP_DB}" \
  -v app_user="${APP_USER}" <<'SQL'
SELECT format('CREATE DATABASE %I OWNER %I TEMPLATE template0', :'app_db', :'app_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'app_db') \gexec
SELECT format('ALTER DATABASE %I OWNER TO %I', :'app_db', :'app_user') \gexec
SQL
