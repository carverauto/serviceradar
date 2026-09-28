-- StarRocks tables for OTel traces: the spans (otel_traces), one summary row per
-- trace (otel_trace_summaries), and the two rollups SRQL rollup_stats reads
-- (traces_stats_5m, spans_red_1h).
-- Not a Mix/Postgres migration; BUILD.bazel here says how these are applied.
--
-- Column names are those of the CNPG relations of the same names, so a reader
-- serves either backend from the same row shape. EventWriter's OtelTraces
-- processor writes spans here, and only here, when StarRocks is enabled; the
-- RefreshTraceSummariesWorker then derives summaries here from those spans.
--
-- otel_traces is keyed (trace_id, span_id, timestamp), the CNPG primary key
-- with the partition column last, so a redelivered span upserts the row it
-- already loaded. Buckets hash on trace_id and the sort key leads with it: the
-- trace detail page looks a trace up by id with no time bound, which then reads
-- one tablet per day partition by its short-key index instead of every row.
--
-- otel_trace_summaries is keyed by trace_id alone and NOT partitioned: a
-- summary's timestamp is the newest span's and moves as late spans arrive, so a
-- day partition would split one trace across two rows. It is sorted by
-- timestamp, so a time-window listing is pruned by zone maps, and the worker
-- deletes rows older than the traces retention, as it does on CNPG.
--
-- The rollups are the CNPG continuous aggregates, partitioned by day in step
-- with otel_traces (see 0017 for why `day` sits beside `bucket`). time_slice
-- floors to a grid anchored at midnight; 5 minutes and 1 hour divide a day, so
-- its buckets are CNPG's time_bucket buckets. percentile_cont interpolates as
-- Postgres's does. RollupFreshness answers from otel_traces while a view is
-- behind.
--
-- partition_live_number is the one-year retention default;
-- SERVICERADAR_STARROCKS_RETENTION_DAYS_TRACES is applied on top at boot.
CREATE DATABASE IF NOT EXISTS serviceradar;

CREATE TABLE IF NOT EXISTS serviceradar.otel_traces (
  trace_id VARCHAR(32) NOT NULL,
  span_id VARCHAR(16) NOT NULL,
  `timestamp` DATETIME NOT NULL,
  parent_span_id VARCHAR(16),
  trace_state VARCHAR(65533),
  name VARCHAR(65533),
  kind INT,
  start_time_unix_nano BIGINT,
  end_time_unix_nano BIGINT,
  service_name VARCHAR(1024),
  service_version VARCHAR(1024),
  service_instance VARCHAR(1024),
  service_namespace VARCHAR(1024),
  deployment_environment VARCHAR(1024),
  scope_name VARCHAR(1024),
  scope_version VARCHAR(1024),
  scope_attributes VARCHAR(1048576),
  status_code INT,
  status_message VARCHAR(65533),
  attributes VARCHAR(1048576),
  resource_attributes VARCHAR(1048576),
  events VARCHAR(1048576),
  links VARCHAR(1048576),
  dropped_attributes_count INT,
  dropped_events_count INT,
  dropped_links_count INT,
  created_at DATETIME,
  ingest_identity VARCHAR(1024),
  ingest_agent_id VARCHAR(256),
  ingest_partition VARCHAR(128)
)
PRIMARY KEY (trace_id, span_id, `timestamp`)
PARTITION BY date_trunc('day', `timestamp`)
DISTRIBUTED BY HASH(trace_id) BUCKETS 8
ORDER BY (trace_id, `timestamp`)
PROPERTIES (
  "replication_num" = "3",
  "enable_persistent_index" = "true",
  "partition_live_number" = "365"
);

CREATE TABLE IF NOT EXISTS serviceradar.otel_trace_summaries (
  trace_id VARCHAR(32) NOT NULL,
  `timestamp` DATETIME,
  root_span_id VARCHAR(16),
  root_span_name VARCHAR(65533),
  root_service_name VARCHAR(1024),
  root_service_namespace VARCHAR(1024),
  deployment_environment VARCHAR(1024),
  root_span_kind INT,
  start_time_unix_nano BIGINT,
  end_time_unix_nano BIGINT,
  duration_ms DOUBLE,
  status_code INT,
  status_message VARCHAR(65533),
  service_set ARRAY<VARCHAR(1024)>,
  span_count BIGINT,
  error_count BIGINT,
  refreshed_at DATETIME
)
PRIMARY KEY (trace_id)
DISTRIBUTED BY HASH(trace_id) BUCKETS 8
ORDER BY (`timestamp`)
PROPERTIES (
  "replication_num" = "3",
  "enable_persistent_index" = "true"
);

CREATE MATERIALIZED VIEW IF NOT EXISTS serviceradar.traces_stats_5m
PARTITION BY day
DISTRIBUTED BY HASH(service_name) BUCKETS 8
REFRESH ASYNC
PROPERTIES (
  "replication_num" = "3"
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

CREATE MATERIALIZED VIEW IF NOT EXISTS serviceradar.spans_red_1h
PARTITION BY day
DISTRIBUTED BY HASH(service_name) BUCKETS 8
REFRESH ASYNC
PROPERTIES (
  "replication_num" = "3"
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
