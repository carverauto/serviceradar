-- Rebuild every rollup with one bucket per day partition.
--
-- The rollups hold kilobytes to a few megabytes a day, yet 0017, 0022, 0025
-- and 0028 gave each day partition eight buckets: on a measured deployment
-- about 2,600 near-empty tablets, a third of the warehouse's tablets, each
-- with its own metadata on every compute node, and each refresh rewrote eight
-- tablets per view. A bucket count cannot be changed on a materialized view,
-- so each is dropped and created again, as 0017 did.
--
-- Like 0028, each is created REFRESH DEFERRED MANUAL with one partition per
-- refresh task, then given its 0038 schedule with ALTER: StarRocks backfills
-- history one day per task on that schedule instead of in one unbounded
-- refresh. Until a view has caught up RollupFreshness reads its raw table, so
-- dashboards stay correct while it fills. The base tables are untouched.
--
-- 0039 runs first, so the backfill reads base partitions already rewritten
-- to their new bucket counts rather than refreshing every day twice.

DROP MATERIALIZED VIEW IF EXISTS serviceradar.ocsf_network_activity_hourly;

CREATE MATERIALIZED VIEW IF NOT EXISTS serviceradar.ocsf_network_activity_hourly
PARTITION BY day
DISTRIBUTED BY HASH(bucket) BUCKETS 1
REFRESH DEFERRED MANUAL
PROPERTIES (
  "replication_num" = "3",
  "partition_refresh_number" = "1"
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

ALTER MATERIALIZED VIEW serviceradar.ocsf_network_activity_hourly REFRESH ASYNC EVERY(INTERVAL 5 MINUTE);

DROP MATERIALIZED VIEW IF EXISTS serviceradar.timeseries_metrics_hourly;

CREATE MATERIALIZED VIEW IF NOT EXISTS serviceradar.timeseries_metrics_hourly
PARTITION BY day
DISTRIBUTED BY HASH(device_id) BUCKETS 1
REFRESH DEFERRED MANUAL
PROPERTIES (
  "replication_num" = "3",
  "partition_refresh_number" = "1"
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

ALTER MATERIALIZED VIEW serviceradar.timeseries_metrics_hourly REFRESH ASYNC EVERY(INTERVAL 5 MINUTE);

DROP MATERIALIZED VIEW IF EXISTS serviceradar.events_hourly;

CREATE MATERIALIZED VIEW IF NOT EXISTS serviceradar.events_hourly
PARTITION BY day
DISTRIBUTED BY HASH(bucket) BUCKETS 1
REFRESH DEFERRED MANUAL
PROPERTIES (
  "replication_num" = "3",
  "partition_refresh_number" = "1"
)
AS
SELECT
  date_trunc('day', `time`) AS day,
  date_trunc('hour', `time`) AS bucket,
  COALESCE(severity_id, 0) AS severity_id,
  COUNT(*) AS total_count
FROM serviceradar.events
GROUP BY date_trunc('day', `time`), date_trunc('hour', `time`), COALESCE(severity_id, 0);

ALTER MATERIALIZED VIEW serviceradar.events_hourly REFRESH ASYNC EVERY(INTERVAL 5 MINUTE);

DROP MATERIALIZED VIEW IF EXISTS serviceradar.traces_stats_5m;

CREATE MATERIALIZED VIEW IF NOT EXISTS serviceradar.traces_stats_5m
PARTITION BY day
DISTRIBUTED BY HASH(service_name) BUCKETS 1
REFRESH DEFERRED MANUAL
PROPERTIES (
  "replication_num" = "3",
  "partition_refresh_number" = "1"
)
AS
SELECT
  date_trunc('day', `timestamp`) AS day,
  time_slice(`timestamp`, INTERVAL 5 MINUTE) AS bucket,
  service_name,
  COUNT(*) AS total_count,
  SUM(CASE WHEN status_code = 2 THEN 1 ELSE 0 END) AS error_count,
  AVG(CAST(end_time_unix_nano - start_time_unix_nano AS DOUBLE) / 1000000.0) AS avg_duration_ms,
  percentile_cont(CAST(end_time_unix_nano - start_time_unix_nano AS DOUBLE) / 1000000.0, 0.95) AS p95_duration_ms
FROM serviceradar.otel_traces
WHERE parent_span_id IS NULL
GROUP BY date_trunc('day', `timestamp`), time_slice(`timestamp`, INTERVAL 5 MINUTE), service_name;

ALTER MATERIALIZED VIEW serviceradar.traces_stats_5m REFRESH ASYNC EVERY(INTERVAL 1 MINUTE);

DROP MATERIALIZED VIEW IF EXISTS serviceradar.spans_red_1h;

CREATE MATERIALIZED VIEW IF NOT EXISTS serviceradar.spans_red_1h
PARTITION BY day
DISTRIBUTED BY HASH(service_name) BUCKETS 1
REFRESH DEFERRED MANUAL
PROPERTIES (
  "replication_num" = "3",
  "partition_refresh_number" = "1"
)
AS
SELECT
  date_trunc('day', `timestamp`) AS day,
  date_trunc('hour', `timestamp`) AS bucket,
  COALESCE(service_name, '') AS service_name,
  COALESCE(service_namespace, '') AS service_namespace,
  COALESCE(deployment_environment, '') AS deployment_environment,
  COUNT(*) AS total_count,
  SUM(CASE WHEN status_code = 2 THEN 1 ELSE 0 END) AS error_count,
  SUM(CASE WHEN CAST(end_time_unix_nano - start_time_unix_nano AS DOUBLE) / 1000000.0 > 100 THEN 1 ELSE 0 END) AS slow_count,
  AVG(CAST(end_time_unix_nano - start_time_unix_nano AS DOUBLE) / 1000000.0) AS avg_duration_ms,
  percentile_cont(CAST(end_time_unix_nano - start_time_unix_nano AS DOUBLE) / 1000000.0, 0.5) AS p50_duration_ms,
  percentile_cont(CAST(end_time_unix_nano - start_time_unix_nano AS DOUBLE) / 1000000.0, 0.95) AS p95_duration_ms,
  MAX(CAST(end_time_unix_nano - start_time_unix_nano AS DOUBLE) / 1000000.0) AS max_duration_ms
FROM serviceradar.otel_traces
GROUP BY
  date_trunc('day', `timestamp`),
  date_trunc('hour', `timestamp`),
  COALESCE(service_name, ''),
  COALESCE(service_namespace, ''),
  COALESCE(deployment_environment, '');

ALTER MATERIALIZED VIEW serviceradar.spans_red_1h REFRESH ASYNC EVERY(INTERVAL 5 MINUTE);

DROP MATERIALIZED VIEW IF EXISTS serviceradar.mtr_hops_hourly;

CREATE MATERIALIZED VIEW IF NOT EXISTS serviceradar.mtr_hops_hourly
PARTITION BY day
DISTRIBUTED BY HASH(addr) BUCKETS 1
REFRESH DEFERRED MANUAL
PROPERTIES (
  "replication_num" = "3",
  "partition_refresh_number" = "1"
)
AS
SELECT
  date_trunc('day', `time`) AS day,
  date_trunc('hour', `time`) AS bucket,
  target_ip,
  device_id,
  addr,
  hop_number,
  SUM(sent) AS sent_total,
  SUM(COALESCE(received, 0)) AS received_total,
  SUM(CAST(avg_us AS DOUBLE) * CAST(COALESCE(received, 0) AS DOUBLE)) AS avg_us_weighted,
  SUM(CAST(min_us AS DOUBLE) * CAST(COALESCE(received, 0) AS DOUBLE)) AS min_us_weighted,
  SUM(CAST(max_us AS DOUBLE) * CAST(COALESCE(received, 0) AS DOUBLE)) AS max_us_weighted,
  SUM(CAST(jitter_us AS DOUBLE) * CAST(COALESCE(received, 0) AS DOUBLE)) AS jitter_us_weighted,
  COUNT(*) AS hop_count
FROM serviceradar.mtr_hops
GROUP BY date_trunc('day', `time`), date_trunc('hour', `time`), target_ip, device_id, addr, hop_number;

ALTER MATERIALIZED VIEW serviceradar.mtr_hops_hourly REFRESH ASYNC EVERY(INTERVAL 5 MINUTE);

DROP MATERIALIZED VIEW IF EXISTS serviceradar.mtr_destination_hourly;

CREATE MATERIALIZED VIEW IF NOT EXISTS serviceradar.mtr_destination_hourly
PARTITION BY day
DISTRIBUTED BY HASH(bucket) BUCKETS 1
REFRESH DEFERRED MANUAL
PROPERTIES (
  "replication_num" = "3",
  "partition_refresh_number" = "1"
)
AS
SELECT
  date_trunc('day', t.`time`) AS day,
  date_trunc('hour', t.`time`) AS bucket,
  COUNT(t.`id`) AS path_count,
  COUNT(dh.trace_id) AS endpoint_sample_count,
  COUNT(CASE WHEN dh.sent > 0 THEN dh.trace_id END) AS loss_sample_count,
  COUNT(CASE WHEN dh.avg_us IS NOT NULL AND dh.received > 0 THEN dh.trace_id END) AS latency_sample_count,
  SUM(CASE WHEN dh.sent > 0 THEN dh.sent END) AS sent_total,
  SUM(CASE WHEN dh.sent > 0 THEN dh.received END) AS received_total,
  SUM(CASE WHEN dh.avg_us IS NOT NULL AND dh.received > 0 THEN CAST(dh.avg_us AS DOUBLE) * dh.received END) AS avg_us_weighted,
  SUM(CASE WHEN dh.avg_us IS NOT NULL AND dh.received > 0 THEN dh.received END) AS latency_weight,
  COUNT(CASE
    WHEN NOT t.target_reached
      OR (dh.sent > dh.received)
      OR (dh.avg_us IS NOT NULL AND dh.received > 0 AND dh.avg_us > 100000)
    THEN t.`id`
  END) AS degraded_count
FROM serviceradar.mtr_traces t
LEFT JOIN (
  SELECT `time`, trace_id, hop_number, sent, received, avg_us
  FROM (
    SELECT
      h.`time`,
      h.trace_id,
      h.hop_number,
      h.sent,
      h.received,
      h.avg_us,
      ROW_NUMBER() OVER (
        PARTITION BY h.`time`, h.trace_id, h.hop_number
        ORDER BY h.`id` DESC
      ) AS terminal_rank
    FROM serviceradar.mtr_hops h
  ) ranked_terminal_hops
  WHERE terminal_rank = 1
) dh ON dh.trace_id = t.`id`
  AND dh.`time` = t.`time`
  AND t.target_reached
  AND dh.hop_number = t.total_hops
GROUP BY date_trunc('day', t.`time`), date_trunc('hour', t.`time`);

ALTER MATERIALIZED VIEW serviceradar.mtr_destination_hourly REFRESH ASYNC EVERY(INTERVAL 5 MINUTE);
