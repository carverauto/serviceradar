-- Free text in OTel spans, BMP routing events, and flow process attribution
-- observations is stored whole. Every value arrives inside one NATS message,
-- which the shipped broker caps at 1 MiB, so VARCHAR(1048576) holds whatever
-- can arrive (as in 0036 and 0037).
-- Protocol-bounded identifier columns (trace_id, span_id, parent_span_id,
-- router_id, router_ip, peer_ip, prefix, agent_id, container_id) keep their
-- width: a value past it is not a valid identifier, and EventWriter stores
-- NULL and counts it rather than a cut one.
-- otel_trace_summaries copies the root span's free text, so its columns
-- widen with the span's; a service name wider than a service_set element
-- (1024 bytes) is left out of the set by TraceSummaries rather than cut.
-- Fresh installs get these widths from 0022, 0024, 0026, and 0031.
-- SchemaMigrator skips a MODIFY whose column already has this type, and awaits
-- each one before the next.
-- traces_stats_5m and spans_red_1h keep the column widths they were created
-- with, so they are dropped before the span columns widen and created again
-- after, exactly as 0040 left them.
DROP MATERIALIZED VIEW IF EXISTS serviceradar.traces_stats_5m;
DROP MATERIALIZED VIEW IF EXISTS serviceradar.spans_red_1h;
ALTER TABLE serviceradar.otel_traces MODIFY COLUMN trace_state VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.otel_traces MODIFY COLUMN name VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.otel_traces MODIFY COLUMN service_name VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.otel_traces MODIFY COLUMN service_version VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.otel_traces MODIFY COLUMN service_instance VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.otel_traces MODIFY COLUMN service_namespace VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.otel_traces MODIFY COLUMN deployment_environment VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.otel_traces MODIFY COLUMN scope_name VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.otel_traces MODIFY COLUMN scope_version VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.otel_traces MODIFY COLUMN status_message VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.otel_traces MODIFY COLUMN ingest_identity VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.otel_traces MODIFY COLUMN ingest_agent_id VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.otel_traces MODIFY COLUMN ingest_partition VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.bmp_routing_events MODIFY COLUMN event_type VARCHAR(1048576) NOT NULL;
ALTER TABLE serviceradar.bmp_routing_events MODIFY COLUMN message VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.bmp_routing_events MODIFY COLUMN raw_data VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.flow_process_attribution_observations MODIFY COLUMN comm VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.flow_process_attribution_observations MODIFY COLUMN cmdline VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.flow_process_attribution_observations MODIFY COLUMN executable_ownership VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.otel_trace_summaries MODIFY COLUMN root_span_name VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.otel_trace_summaries MODIFY COLUMN root_service_name VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.otel_trace_summaries MODIFY COLUMN root_service_namespace VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.otel_trace_summaries MODIFY COLUMN deployment_environment VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.otel_trace_summaries MODIFY COLUMN status_message VARCHAR(1048576) NULL;

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
