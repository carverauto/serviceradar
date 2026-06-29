-- Minimal isolated schema for the end-to-end core seasonal proof: the raw
-- timeseries_metrics hypertable + the REAL timeseries_metrics_hourly continuous
-- aggregate (the relevant subset of migration 20260220110000_add_srql_metric_hourly_caggs),
-- created in `public` so the verb's unqualified table name resolves. Run via psql
-- (autocommit) — a continuous aggregate cannot be created inside a transaction.
CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE timeseries_metrics (
  timestamp   timestamptz NOT NULL,
  device_id   text,
  metric_type text,
  metric_name text,
  value       double precision
);
SELECT create_hypertable('timeseries_metrics', 'timestamp');

CREATE MATERIALIZED VIEW timeseries_metrics_hourly
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 hour', timestamp) AS bucket,
  device_id,
  metric_type,
  metric_name,
  AVG(value)::float8   AS avg_value,
  MIN(value)::float8   AS min_value,
  MAX(value)::float8   AS max_value,
  COUNT(*)::bigint     AS sample_count
FROM timeseries_metrics
GROUP BY 1, 2, 3, 4
WITH NO DATA;
