-- =================================================================
-- == Performance Analytics Stream Migration
-- =================================================================
-- Add otel_metrics table for OpenTelemetry trace-derived analytics

-- OTEL metrics table optimized for trace analytics
CREATE STREAM IF NOT EXISTS otel_metrics (
    -- Core trace identifiers
    timestamp         DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    trace_id          string CODEC(ZSTD(1)),
    span_id           string CODEC(ZSTD(1)),
    
    -- Service and span information
    service_name      string CODEC(ZSTD(1)),
    span_name         string CODEC(ZSTD(1)),
    span_kind         string CODEC(ZSTD(1)),
    
    -- Performance measurements
    duration_ms       float64 CODEC(ZSTD(1)),
    duration_seconds  float64 CODEC(ZSTD(1)),
    metric_type       string CODEC(ZSTD(1)),  -- "span", "http", "grpc", "slow_span"
    
    -- HTTP-specific fields
    http_method       string CODEC(ZSTD(1)),
    http_route        string CODEC(ZSTD(1)),
    http_status_code  string CODEC(ZSTD(1)),
    
    -- gRPC-specific fields
    grpc_service      string CODEC(ZSTD(1)),
    grpc_method       string CODEC(ZSTD(1)),
    grpc_status_code  string CODEC(ZSTD(1)),
    
    -- Performance flags and metadata
    is_slow           bool CODEC(ZSTD(1)),     -- true if > 100ms
    component         string CODEC(ZSTD(1)),   -- "otel-collector"
    level             string CODEC(ZSTD(1)),   -- "info", "warn" for slow spans
    
    -- Raw JSON data for debugging/reprocessing
    raw_data          string CODEC(ZSTD(1))
    
) ENGINE = Stream(1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 3600)  -- Hourly partitions
ORDER BY (service_name, timestamp, trace_id, span_id)
SETTINGS index_granularity = 8192;

-- Create indexes for common query patterns
-- Uncomment these after table creation if needed for performance:

-- Service-based queries
-- ALTER TABLE otel_metrics ADD INDEX service_name_idx service_name TYPE bloom_filter GRANULARITY 1;

-- Trace-based queries for correlation with logs
-- ALTER TABLE otel_metrics ADD INDEX trace_id_idx trace_id TYPE bloom_filter GRANULARITY 1;

-- Performance analysis queries
-- ALTER TABLE otel_metrics ADD INDEX duration_idx duration_ms TYPE minmax GRANULARITY 1;
-- ALTER TABLE otel_metrics ADD INDEX slow_spans_idx is_slow TYPE bloom_filter GRANULARITY 1;

-- HTTP/gRPC specific analysis
-- ALTER TABLE otel_metrics ADD INDEX http_method_idx http_method TYPE bloom_filter GRANULARITY 1;
-- ALTER TABLE otel_metrics ADD INDEX metric_type_idx metric_type TYPE bloom_filter GRANULARITY 1;