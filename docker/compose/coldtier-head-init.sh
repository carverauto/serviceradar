#!/bin/sh
# Unused by compose (analytics-head-init.sql is the initdb source).
# Kept so an old volume mount of this path does not re-enable postgres_fdw.
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
	CREATE EXTENSION IF NOT EXISTS pg_duckdb;
	CREATE SCHEMA IF NOT EXISTS platform;
EOSQL
