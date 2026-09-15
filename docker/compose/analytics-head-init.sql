-- Analytics-head initdb (compose profile analytics / analytics-fs).
-- pg_duckdb only. Do not create postgres_fdw: the head is the store, not a
-- stitch against the Timescale primary.
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE SCHEMA IF NOT EXISTS platform;
