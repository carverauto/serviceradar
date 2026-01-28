#!/bin/sh
set -eu

APP_USER="${CNPG_APP_USER:-serviceradar}"
SPIRE_USER="${CNPG_SPIRE_USER:-spire}"
APP_PASS_FILE="${CNPG_APP_PASSWORD_FILE:-/etc/serviceradar/cnpg/serviceradar-password}"
SPIRE_PASS_FILE="${CNPG_SPIRE_PASSWORD_FILE:-/etc/serviceradar/cnpg/spire-password}"

APP_PASS=""
SPIRE_PASS=""

if [ -f "$APP_PASS_FILE" ]; then
  APP_PASS="$(tr -d '\r\n' < "$APP_PASS_FILE")"
fi
if [ -z "$APP_PASS" ]; then
  APP_PASS="${CNPG_PASSWORD:-}"
fi
if [ -z "$APP_PASS" ]; then
  echo "Missing app password for $APP_USER (set $APP_PASS_FILE or CNPG_PASSWORD)" >&2
  exit 1
fi

if [ -f "$SPIRE_PASS_FILE" ]; then
  SPIRE_PASS="$(tr -d '\r\n' < "$SPIRE_PASS_FILE")"
fi
if [ -z "$SPIRE_PASS" ]; then
  SPIRE_PASS="${CNPG_SPIRE_PASSWORD:-}"
fi
if [ -z "$SPIRE_PASS" ]; then
  echo "Missing spire password for $SPIRE_USER (set $SPIRE_PASS_FILE or CNPG_SPIRE_PASSWORD)" >&2
  exit 1
fi

psql -v ON_ERROR_STOP=1 \
  -v app_user="$APP_USER" \
  -v app_pass="$APP_PASS" \
  -v spire_user="$SPIRE_USER" \
  -v spire_pass="$SPIRE_PASS" \
  --username "$POSTGRES_USER" \
  --dbname "$POSTGRES_DB" <<'EOSQL'
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS age;

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'spire_user', :'spire_pass')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'spire_user');
\gexec

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_pass')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user');
\gexec

SELECT format('CREATE DATABASE %I OWNER %I', 'serviceradar', :'app_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'serviceradar');
\gexec

ALTER DATABASE serviceradar OWNER TO :"app_user";
CREATE SCHEMA IF NOT EXISTS platform AUTHORIZATION :"app_user";
ALTER DATABASE serviceradar SET search_path TO platform, ag_catalog;
ALTER ROLE :"app_user" SET search_path TO platform, ag_catalog;

SELECT format('ALTER TABLE IF EXISTS platform.oban_jobs OWNER TO %I', :'app_user')
FROM pg_namespace WHERE nspname = 'platform';
\gexec

SELECT format('ALTER TABLE IF EXISTS platform.oban_peers OWNER TO %I', :'app_user')
FROM pg_namespace WHERE nspname = 'platform';
\gexec

SELECT format('ALTER SEQUENCE IF EXISTS platform.oban_jobs_id_seq OWNER TO %I', :'app_user')
FROM pg_namespace WHERE nspname = 'platform';
\gexec
EOSQL
