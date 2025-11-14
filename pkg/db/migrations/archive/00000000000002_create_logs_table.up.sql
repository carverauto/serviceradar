-- =================================================================
-- == OTEL Logs Stream Migration
-- =================================================================
-- Add logs table for OpenTelemetry logs storage separate from events

-- OTEL logs table optimized for observability data
CREATE STREAM IF NOT EXISTS logs (
    -- Core log fields
    timestamp         DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    trace_id          string CODEC(ZSTD(1)),
    span_id           string CODEC(ZSTD(1)),
    severity_text     string CODEC(ZSTD(1)),
    severity_number   int32 CODEC(ZSTD(1)),
    body              string CODEC(ZSTD(1)),
    
    -- Service identification
    service_name      string CODEC(ZSTD(1)),
    service_version   string CODEC(ZSTD(1)),
    service_instance  string CODEC(ZSTD(1)),
    
    -- Instrumentation scope
    scope_name        string CODEC(ZSTD(1)),
    scope_version     string CODEC(ZSTD(1)),
    
    -- Attributes as comma-separated key=value pairs
    attributes        string CODEC(ZSTD(1)),
    resource_attributes string CODEC(ZSTD(1)),
    
    -- Raw protobuf data for debugging/reprocessing
    raw_data          string CODEC(ZSTD(1))
    
) ENGINE = Stream(1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 3600)  -- Hourly partitions
ORDER BY (service_name, timestamp, trace_id, span_id)
SETTINGS index_granularity = 8192;

-- Create indexes for common query patterns
-- Uncomment these after table creation if needed for performance:

-- Service-based queries
-- ALTER TABLE logs ADD INDEX service_name_idx service_name TYPE bloom_filter GRANULARITY 1;

-- Trace-based queries  
-- ALTER TABLE logs ADD INDEX trace_id_idx trace_id TYPE bloom_filter GRANULARITY 1;

-- Severity-based queries
-- ALTER TABLE logs ADD INDEX severity_idx severity_text TYPE bloom_filter GRANULARITY 1;

-- Body text search (use with caution - can be expensive)
-- ALTER TABLE logs ADD INDEX body_idx body TYPE tokenbf_v1(32768, 3, 0) GRANULARITY 1;