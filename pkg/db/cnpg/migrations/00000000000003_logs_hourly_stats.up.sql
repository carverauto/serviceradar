-- Migration: Create continuous aggregation for logs severity stats
-- This migration adds a continuous aggregate for hourly log severity counts
-- to improve query performance for observability dashboard stat cards.

-- Create continuous aggregation for logs hourly stats
-- Pre-computes severity counts by hour for fast dashboard queries
CREATE MATERIALIZED VIEW IF NOT EXISTS logs_hourly_stats
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 hour', timestamp) AS bucket,
    service_name,
    COUNT(*) AS total_count,
    COUNT(*) FILTER (WHERE
        severity_text IN ('fatal', 'FATAL', 'critical', 'CRITICAL')
    ) AS fatal_count,
    COUNT(*) FILTER (WHERE
        severity_text IN ('error', 'ERROR', 'err', 'ERR')
    ) AS error_count,
    COUNT(*) FILTER (WHERE
        severity_text IN ('warning', 'WARNING', 'warn', 'WARN')
    ) AS warning_count,
    COUNT(*) FILTER (WHERE
        severity_text IN ('info', 'INFO', 'information', 'INFORMATION')
    ) AS info_count,
    COUNT(*) FILTER (WHERE
        severity_text IN ('debug', 'DEBUG', 'trace', 'TRACE')
    ) AS debug_count
FROM logs
GROUP BY bucket, service_name
WITH NO DATA;

-- Add refresh policy to update the continuous aggregation every 15 minutes
-- The end_offset must be >= bucket size (1 hour) for TimescaleDB
SELECT add_continuous_aggregate_policy('logs_hourly_stats',
    start_offset => INTERVAL '3 hours',
    end_offset => INTERVAL '1 hour',
    schedule_interval => INTERVAL '15 minutes',
    if_not_exists => TRUE
);

-- Create indexes on the continuous aggregation for efficient time-range queries
CREATE INDEX IF NOT EXISTS idx_logs_hourly_stats_bucket
ON logs_hourly_stats (bucket DESC);

CREATE INDEX IF NOT EXISTS idx_logs_hourly_stats_service_bucket
ON logs_hourly_stats (service_name, bucket DESC);

-- Grant permissions to spire role if it exists
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'spire') THEN
        GRANT SELECT ON TABLE logs_hourly_stats TO spire;
    END IF;
END $$;

-- Add comment explaining the view
COMMENT ON VIEW logs_hourly_stats IS
'Continuous aggregate for hourly log severity counts. Used by observability dashboard stat cards.';
