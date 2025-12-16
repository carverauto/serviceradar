-- Migration: Add unit column to otel_metrics and create continuous aggregation for stats
-- This migration adds:
-- 1. A `unit` column to store the metric's unit of measurement (e.g., "ms", "bytes", "1")
-- 2. A continuous aggregation for hourly metrics stats to improve query performance

-- Add unit column to otel_metrics
ALTER TABLE otel_metrics ADD COLUMN IF NOT EXISTS unit TEXT;

-- Create index on unit for filtering
CREATE INDEX IF NOT EXISTS idx_otel_metrics_unit ON otel_metrics (unit);

-- Create continuous aggregation for otel_metrics hourly stats
-- This provides pre-computed counts for total, errors, and slow spans
CREATE MATERIALIZED VIEW IF NOT EXISTS otel_metrics_hourly_stats
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 hour', timestamp) AS bucket,
    service_name,
    metric_type,
    COUNT(*) AS total_count,
    COUNT(*) FILTER (WHERE is_slow = true) AS slow_count,
    COUNT(*) FILTER (WHERE
        level IN ('error', 'ERROR', 'Error') OR
        http_status_code LIKE '4%' OR
        http_status_code LIKE '5%' OR
        (grpc_status_code IS NOT NULL AND grpc_status_code <> '0' AND grpc_status_code <> '')
    ) AS error_count,
    COUNT(*) FILTER (WHERE http_status_code LIKE '4%') AS http_4xx_count,
    COUNT(*) FILTER (WHERE http_status_code LIKE '5%') AS http_5xx_count,
    COUNT(*) FILTER (WHERE grpc_status_code IS NOT NULL AND grpc_status_code <> '0' AND grpc_status_code <> '') AS grpc_error_count,
    AVG(duration_ms) FILTER (WHERE duration_ms IS NOT NULL) AS avg_duration_ms,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY duration_ms) FILTER (WHERE duration_ms IS NOT NULL) AS p95_duration_ms,
    MAX(duration_ms) FILTER (WHERE duration_ms IS NOT NULL) AS max_duration_ms
FROM otel_metrics
GROUP BY bucket, service_name, metric_type
WITH NO DATA;

-- Add refresh policy to update the continuous aggregation every 15 minutes
-- The end_offset must be >= bucket size (1 hour) for TimescaleDB
SELECT add_continuous_aggregate_policy('otel_metrics_hourly_stats',
    start_offset => INTERVAL '3 hours',
    end_offset => INTERVAL '1 hour',
    schedule_interval => INTERVAL '15 minutes',
    if_not_exists => TRUE
);

-- Create index on the continuous aggregation for efficient time-range queries
CREATE INDEX IF NOT EXISTS idx_otel_metrics_hourly_stats_bucket
ON otel_metrics_hourly_stats (bucket DESC);

CREATE INDEX IF NOT EXISTS idx_otel_metrics_hourly_stats_service_bucket
ON otel_metrics_hourly_stats (service_name, bucket DESC);

-- Grant permissions to spire role if it exists
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'spire') THEN
        GRANT SELECT ON TABLE otel_metrics_hourly_stats TO spire;
    END IF;
END $$;

-- Add comment explaining the unit column
COMMENT ON COLUMN otel_metrics.unit IS 'Unit of measurement for the metric value (e.g., "ms", "s", "bytes", "1" for counts)';
