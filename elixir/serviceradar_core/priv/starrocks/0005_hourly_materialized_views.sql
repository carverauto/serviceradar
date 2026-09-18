-- Asynchronous hourly MVs for dashboard aggregates.
-- Primary Key raw tables do not support synchronous MVs (StarRocks 3.5).
-- Applied by the Bazel schema target, not Mix/Postgres migrations.
--
-- Every stored aggregate must be re-aggregatable into a coarser bucket by the
-- SRQL compiler, and must equal what the same query computes from the raw
-- table: flow byte/packet totals therefore carry the sampling weight and the
-- bytes_total/packets_total fallback the compiler applies, and the metric MV
-- keeps sample_count so AVG and SUM stay exact across hours.
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
  SUM(COALESCE(bytes_total, COALESCE(bytes_in, 0) + COALESCE(bytes_out, 0)) * GREATEST(COALESCE(sampling_rate, 1), 1)) AS bytes_total,
  SUM(COALESCE(packets_total, COALESCE(packets_in, 0) + COALESCE(packets_out, 0)) * GREATEST(COALESCE(sampling_rate, 1), 1)) AS packets_total,
  SUM(COALESCE(bytes_in, 0) * GREATEST(COALESCE(sampling_rate, 1), 1)) AS bytes_in,
  SUM(COALESCE(bytes_out, 0) * GREATEST(COALESCE(sampling_rate, 1), 1)) AS bytes_out,
  SUM(COALESCE(packets_in, 0) * GREATEST(COALESCE(sampling_rate, 1), 1)) AS packets_in,
  SUM(COALESCE(packets_out, 0) * GREATEST(COALESCE(sampling_rate, 1), 1)) AS packets_out,
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
