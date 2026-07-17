#!/bin/sh
# Cold-tier analytics head bootstrap (profile: coldtier).
# Mirrors postInitApplicationSQL in helm/serviceradar/templates/cold-analytics-head.yaml.
# Runs once at initdb time via /docker-entrypoint-initdb.d.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
	CREATE EXTENSION IF NOT EXISTS pg_duckdb;
	CREATE EXTENSION IF NOT EXISTS postgres_fdw;
	CREATE SCHEMA IF NOT EXISTS platform AUTHORIZATION "$POSTGRES_USER";
	ALTER ROLE "$POSTGRES_USER" SET search_path TO platform, public;
EOSQL
