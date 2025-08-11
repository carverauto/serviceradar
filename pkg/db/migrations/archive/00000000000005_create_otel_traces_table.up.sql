-- =================================================================
-- == OTEL Traces Stream Migration
-- =================================================================
-- Add otel_traces table for OpenTelemetry trace storage

-- OTEL traces table for storing raw trace spans
CREATE STREAM IF NOT EXISTS otel_traces (
    -- Core span identifiers
    timestamp         DateTime64(9) CODEC(Delta(8), ZSTD(1)),  -- start_time_unix_nano
    trace_id          string CODEC(ZSTD(1)),
    span_id           string CODEC(ZSTD(1)),
    parent_span_id    string CODEC(ZSTD(1)),
    
    -- Span details
    name              string CODEC(ZSTD(1)),
    kind              int32 CODEC(ZSTD(1)),  -- SpanKind enum value
    start_time_unix_nano uint64 CODEC(Delta(8), ZSTD(1)),
    end_time_unix_nano   uint64 CODEC(Delta(8), ZSTD(1)),
    
    -- Service identification
    service_name      string CODEC(ZSTD(1)),
    service_version   string CODEC(ZSTD(1)),
    service_instance  string CODEC(ZSTD(1)),
    
    -- Instrumentation scope
    scope_name        string CODEC(ZSTD(1)),
    scope_version     string CODEC(ZSTD(1)),
    
    -- Status
    status_code       int32 CODEC(ZSTD(1)),   -- Status code enum
    status_message    string CODEC(ZSTD(1)),
    
    -- Attributes as comma-separated key=value pairs
    attributes        string CODEC(ZSTD(1)),
    resource_attributes string CODEC(ZSTD(1)),
    
    -- Events (JSON array)
    events            string CODEC(ZSTD(1)),
    
    -- Links (JSON array)
    links             string CODEC(ZSTD(1)),
    
    -- Raw protobuf data for debugging/reprocessing
    raw_data          string CODEC(ZSTD(1))
    
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 3600)  -- Hourly partitions
ORDER BY (service_name, timestamp, trace_id, span_id)
SETTINGS index_granularity = 8192;

-- Create indexes for common query patterns
-- Uncomment these after table creation if needed for performance:

-- Service-based queries
-- ALTER TABLE otel_traces ADD INDEX service_name_idx service_name TYPE bloom_filter GRANULARITY 1;

-- Trace-based queries for full trace reconstruction
-- ALTER TABLE otel_traces ADD INDEX trace_id_idx trace_id TYPE bloom_filter GRANULARITY 1;

-- Parent-child span relationships
-- ALTER TABLE otel_traces ADD INDEX parent_span_idx parent_span_id TYPE bloom_filter GRANULARITY 1;

-- Span name analysis
-- ALTER TABLE otel_traces ADD INDEX span_name_idx name TYPE bloom_filter GRANULARITY 1;

-- Error/status analysis
-- ALTER TABLE otel_traces ADD INDEX status_idx status_code TYPE bloom_filter GRANULARITY 1;