-- Adjust otel_trace_summaries to use daily partitions. This avoids breaching
-- max_partitions_per_insert_block when backfilling traces that span more than
-- ~100 hours while keeping the schema aligned with the consolidated migration.

DROP VIEW IF EXISTS otel_trace_summaries_mv;
DROP VIEW IF EXISTS otel_trace_summaries_final_mv;
DROP VIEW IF EXISTS otel_trace_summaries_deduplicated;
DROP VIEW IF EXISTS otel_trace_summaries_final_v2;
DROP VIEW IF EXISTS otel_trace_summaries_final;
DROP VIEW IF EXISTS otel_trace_summaries_dedup;

DROP STREAM IF EXISTS otel_trace_summaries;

CREATE STREAM IF NOT EXISTS otel_trace_summaries (
    timestamp         DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    trace_id          string CODEC(ZSTD(1)),
    root_span_id      string CODEC(ZSTD(1)),
    root_span_name    string CODEC(ZSTD(1)),
    root_service_name string CODEC(ZSTD(1)),
    root_span_kind    int32 CODEC(ZSTD(1)),
    start_time_unix_nano uint64 CODEC(Delta(8), ZSTD(1)),
    end_time_unix_nano   uint64 CODEC(Delta(8), ZSTD(1)),
    duration_ms          float64 CODEC(ZSTD(1)),
    status_code       int32 CODEC(ZSTD(1)),
    service_set       array(string) CODEC(ZSTD(1)),
    span_count        uint32 CODEC(ZSTD(1)),
    error_count       uint32 CODEC(ZSTD(1))
) ENGINE = Stream(1, rand())
PARTITION BY to_start_of_day(timestamp)
ORDER BY (timestamp, trace_id)
TTL to_start_of_day(_tp_time) + INTERVAL 3 DAY
SETTINGS index_granularity = 8192;

CREATE MATERIALIZED VIEW IF NOT EXISTS otel_trace_summaries_mv
INTO otel_trace_summaries AS
SELECT
    min(timestamp) AS timestamp,
    trace_id,
    any_if(span_id, is_root) AS root_span_id,
    any_if(name, is_root) AS root_span_name,
    any_if(service_name, is_root) AS root_service_name,
    any_if(kind, is_root) AS root_span_kind,
    min(start_time_unix_nano) AS start_time_unix_nano,
    max(end_time_unix_nano) AS end_time_unix_nano,
    any_if(duration_ms, is_root) AS duration_ms,
    max(status_code) AS status_code,
    group_uniq_array(service_name) AS service_set,
    count() AS span_count,
    0 AS error_count
FROM otel_spans_enriched
GROUP BY trace_id;

CREATE VIEW IF NOT EXISTS otel_trace_summaries_dedup AS
SELECT
    trace_id,
    timestamp,
    timestamp as _tp_time,
    root_span_id,
    root_span_name,
    root_service_name,
    root_span_kind,
    start_time_unix_nano,
    end_time_unix_nano,
    duration_ms,
    span_count,
    error_count,
    status_code,
    service_set
FROM otel_trace_summaries;

CREATE OR REPLACE VIEW otel_trace_summaries_final       AS SELECT * FROM otel_trace_summaries_dedup;
CREATE OR REPLACE VIEW otel_trace_summaries_final_v2    AS SELECT * FROM otel_trace_summaries_dedup;
CREATE OR REPLACE VIEW otel_trace_summaries_deduplicated AS SELECT * FROM otel_trace_summaries_dedup;

ALTER STREAM otel_trace_summaries ADD INDEX IF NOT EXISTS idx_timestamp timestamp TYPE minmax GRANULARITY 1;
ALTER STREAM otel_trace_summaries ADD INDEX IF NOT EXISTS idx_trace_id trace_id TYPE bloom_filter GRANULARITY 1;
ALTER STREAM otel_trace_summaries ADD INDEX IF NOT EXISTS idx_service root_service_name TYPE bloom_filter GRANULARITY 1;
ALTER STREAM otel_trace_summaries ADD INDEX IF NOT EXISTS idx_duration duration_ms TYPE minmax GRANULARITY 1;

-- NOTE: Historical data backfill is intentionally omitted here. The original
-- migration attempted to read from otel_spans_enriched (Stream engine) and
-- would block on empty deployments. New installs receive the updated schema
-- directly from the consolidated migration, and existing clusters will
-- repopulate the summaries via the live materialized view pipeline.
