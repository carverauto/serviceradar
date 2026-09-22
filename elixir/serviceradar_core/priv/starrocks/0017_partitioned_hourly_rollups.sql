-- Hourly rollups that refresh one day at a time.
-- Not a Mix/Postgres migration; BUILD.bazel here says how these are applied.
--
-- The rollups from 0005 and 0016 are unpartitioned, so every refresh
-- recomputes the whole view from the whole base table, and the cost of keeping
-- a rollup current grows with everything the warehouse has ever stored. A
-- rollup partitioned in step with its base table refreshes only the days whose
-- base partitions changed, which in steady state is today's.
--
-- StarRocks will not partition a view by date_trunc('day', bucket): the
-- partition expression has to be a column that is itself date_trunc of the
-- base table's partition column. Each view therefore carries `day` beside
-- `bucket`. Readers name their columns, so the extra one is invisible to them.
--
-- This needs partitioned base tables. On a warehouse created before daily
-- partitioning, PartitionRebuild has already rebuilt them by the time this
-- runs; were it ever not so, the CREATE fails and nothing is recorded, rather
-- than quietly leaving a rollup that refreshes in full.
--
-- Safe to run at any time: a rollup is derived state, StarRocks refills it
-- after creation, and RollupFreshness answers from the raw table until it has.
DROP MATERIALIZED VIEW IF EXISTS serviceradar.ocsf_network_activity_hourly;

CREATE MATERIALIZED VIEW IF NOT EXISTS serviceradar.ocsf_network_activity_hourly
PARTITION BY day
DISTRIBUTED BY HASH(bucket) BUCKETS 8
REFRESH ASYNC
PROPERTIES (
  "replication_num" = "3"
)
AS
SELECT
  date_trunc('day', `time`) AS day,
  date_trunc('hour', `time`) AS bucket,
  SUM(COALESCE(bytes_total, COALESCE(bytes_in, 0) + COALESCE(bytes_out, 0)) * GREATEST(COALESCE(sampling_rate, 1), 1)) AS bytes_total,
  SUM(COALESCE(packets_total, COALESCE(packets_in, 0) + COALESCE(packets_out, 0)) * GREATEST(COALESCE(sampling_rate, 1), 1)) AS packets_total,
  SUM(COALESCE(bytes_in, 0) * GREATEST(COALESCE(sampling_rate, 1), 1)) AS bytes_in,
  SUM(COALESCE(bytes_out, 0) * GREATEST(COALESCE(sampling_rate, 1), 1)) AS bytes_out,
  SUM(COALESCE(packets_in, 0) * GREATEST(COALESCE(sampling_rate, 1), 1)) AS packets_in,
  SUM(COALESCE(packets_out, 0) * GREATEST(COALESCE(sampling_rate, 1), 1)) AS packets_out,
  COUNT(*) AS flow_count
FROM serviceradar.ocsf_network_activity
GROUP BY date_trunc('day', `time`), date_trunc('hour', `time`);

DROP MATERIALIZED VIEW IF EXISTS serviceradar.timeseries_metrics_hourly;

CREATE MATERIALIZED VIEW IF NOT EXISTS serviceradar.timeseries_metrics_hourly
PARTITION BY day
DISTRIBUTED BY HASH(device_id) BUCKETS 8
REFRESH ASYNC
PROPERTIES (
  "replication_num" = "3"
)
AS
SELECT
  date_trunc('day', `timestamp`) AS day,
  date_trunc('hour', `timestamp`) AS bucket,
  device_id,
  metric_type,
  metric_name,
  AVG(value) AS avg_value,
  MIN(value) AS min_value,
  MAX(value) AS max_value,
  COUNT(*) AS sample_count
FROM serviceradar.timeseries_metrics
GROUP BY date_trunc('day', `timestamp`), date_trunc('hour', `timestamp`), device_id, metric_type, metric_name;

DROP MATERIALIZED VIEW IF EXISTS serviceradar.events_hourly;

CREATE MATERIALIZED VIEW IF NOT EXISTS serviceradar.events_hourly
PARTITION BY day
DISTRIBUTED BY HASH(bucket) BUCKETS 8
REFRESH ASYNC
PROPERTIES (
  "replication_num" = "3"
)
AS
SELECT
  date_trunc('day', `time`) AS day,
  date_trunc('hour', `time`) AS bucket,
  COALESCE(severity_id, 0) AS severity_id,
  COUNT(*) AS total_count
FROM serviceradar.events
GROUP BY date_trunc('day', `time`), date_trunc('hour', `time`), COALESCE(severity_id, 0);
