-- Asynchronous hourly MVs for dashboard aggregates.
-- Primary Key raw tables do not support synchronous MVs (StarRocks 3.5).
-- Applied by the Bazel schema target, not Mix/Postgres migrations.
CREATE DATABASE IF NOT EXISTS serviceradar;

CREATE MATERIALIZED VIEW IF NOT EXISTS serviceradar.ocsf_network_activity_hourly
DISTRIBUTED BY HASH(bucket) BUCKETS 8
REFRESH ASYNC
PROPERTIES (
  "replication_num" = "3"
)
AS
SELECT
  date_trunc('hour', `time`) AS bucket,
  SUM(bytes_in) AS bytes_in,
  SUM(bytes_out) AS bytes_out,
  SUM(packets_in) AS packets_in,
  SUM(packets_out) AS packets_out,
  COUNT(*) AS flow_count
FROM serviceradar.ocsf_network_activity
GROUP BY date_trunc('hour', `time`);

CREATE MATERIALIZED VIEW IF NOT EXISTS serviceradar.timeseries_metrics_hourly
DISTRIBUTED BY HASH(device_id) BUCKETS 8
REFRESH ASYNC
PROPERTIES (
  "replication_num" = "3"
)
AS
SELECT
  date_trunc('hour', `timestamp`) AS bucket,
  device_id,
  metric_type,
  metric_name,
  AVG(value) AS avg_value,
  MIN(value) AS min_value,
  MAX(value) AS max_value,
  COUNT(*) AS sample_count
FROM serviceradar.timeseries_metrics
GROUP BY date_trunc('hour', `timestamp`), device_id, metric_type, metric_name;

CREATE MATERIALIZED VIEW IF NOT EXISTS serviceradar.events_hourly
DISTRIBUTED BY HASH(bucket) BUCKETS 8
REFRESH ASYNC
PROPERTIES (
  "replication_num" = "3"
)
AS
SELECT
  date_trunc('hour', `time`) AS bucket,
  COALESCE(severity_id, 0) AS severity_id,
  COUNT(*) AS total_count
FROM serviceradar.events
GROUP BY date_trunc('hour', `time`), COALESCE(severity_id, 0);
