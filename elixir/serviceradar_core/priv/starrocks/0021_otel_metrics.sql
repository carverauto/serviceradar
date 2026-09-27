-- StarRocks primary-key tables for OTel metrics: span-derived performance
-- samples (otel_metrics) and OTLP metric data points (otel_metric_points).
-- Not a Mix/Postgres migration; BUILD.bazel here says how these are applied.
--
-- Column names are those of platform.otel_metrics and platform.otel_metric_points,
-- so a reader serves either backend from the same row shape. EventWriter's
-- OtelMetrics processor writes here, and only here, when StarRocks is enabled;
-- otherwise it writes CNPG.
--
-- The key is (id, `timestamp`): StarRocks requires the partition column in the
-- primary key, and id is derived from the rest of the CNPG primary key
-- (span_name, service_name, span_id for a sample; metric_name, service_name,
-- attributes_hash for a point), so the pair enforces exactly the uniqueness
-- CNPG does and a redelivered message upserts the rows it already loaded.
--
-- partition_live_number is the one-year retention default;
-- SERVICERADAR_STARROCKS_RETENTION_DAYS_OTEL is applied on top at boot, to both
-- tables.
--
-- Text columns are sized so that no value the processor writes is wider than
-- its column: StarRocks filters such a row out of a Stream Load batch.
CREATE DATABASE IF NOT EXISTS serviceradar;

CREATE TABLE IF NOT EXISTS serviceradar.otel_metrics (
  id VARCHAR(64) NOT NULL,
  `timestamp` DATETIME NOT NULL,
  trace_id VARCHAR(128),
  span_id VARCHAR(64),
  service_name VARCHAR(1024),
  span_name VARCHAR(4096),
  span_kind VARCHAR(64),
  duration_ms DOUBLE,
  duration_seconds DOUBLE,
  metric_type VARCHAR(256),
  http_method VARCHAR(64),
  http_route VARCHAR(4096),
  http_status_code VARCHAR(64),
  grpc_service VARCHAR(1024),
  grpc_method VARCHAR(1024),
  grpc_status_code VARCHAR(64),
  is_slow BOOLEAN,
  component VARCHAR(1024),
  level VARCHAR(64),
  unit VARCHAR(256),
  ingest_identity VARCHAR(1024),
  ingest_agent_id VARCHAR(256),
  ingest_partition VARCHAR(128),
  created_at DATETIME
)
PRIMARY KEY (id, `timestamp`)
PARTITION BY date_trunc('day', `timestamp`)
DISTRIBUTED BY HASH(id) BUCKETS 8
ORDER BY (`timestamp`, id)
PROPERTIES (
  "replication_num" = "3",
  "enable_persistent_index" = "true",
  "partition_live_number" = "365"
);

CREATE TABLE IF NOT EXISTS serviceradar.otel_metric_points (
  id VARCHAR(64) NOT NULL,
  `timestamp` DATETIME NOT NULL,
  metric_name VARCHAR(1024) NOT NULL,
  metric_type VARCHAR(64),
  unit VARCHAR(256),
  temporality VARCHAR(64),
  is_monotonic BOOLEAN,
  service_name VARCHAR(1024),
  attributes VARCHAR(1048576),
  attributes_hash VARCHAR(128),
  value DOUBLE,
  count BIGINT,
  sum DOUBLE,
  bucket_counts VARCHAR(1048576),
  explicit_bounds VARCHAR(1048576),
  start_time_unix_nano BIGINT,
  scope_name VARCHAR(1024),
  service_instance_id VARCHAR(1024),
  ingest_identity VARCHAR(1024),
  ingest_agent_id VARCHAR(256),
  ingest_partition VARCHAR(128),
  created_at DATETIME
)
PRIMARY KEY (id, `timestamp`)
PARTITION BY date_trunc('day', `timestamp`)
DISTRIBUTED BY HASH(id) BUCKETS 8
ORDER BY (`timestamp`, id)
PROPERTIES (
  "replication_num" = "3",
  "enable_persistent_index" = "true",
  "partition_live_number" = "365"
);
