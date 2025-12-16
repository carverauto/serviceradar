-- Migration: Add metric_name and value columns to otel_metrics
-- These columns support gauge/counter metrics which need:
-- - metric_name: identifier for the metric (e.g., "cpu_usage", "request_count")
-- - value: the numeric value of the metric

-- Add metric_name column for gauge/counter metric identification
ALTER TABLE otel_metrics ADD COLUMN IF NOT EXISTS metric_name TEXT;

-- Add value column for gauge/counter metric values
ALTER TABLE otel_metrics ADD COLUMN IF NOT EXISTS value DOUBLE PRECISION;

-- Create index for efficient metric_name lookups with time filtering
CREATE INDEX IF NOT EXISTS idx_otel_metrics_metric_name_time
ON otel_metrics (metric_name, timestamp DESC)
WHERE metric_name IS NOT NULL;

-- Create index for metric_type + metric_name queries (sparklines)
CREATE INDEX IF NOT EXISTS idx_otel_metrics_type_name_time
ON otel_metrics (metric_type, metric_name, timestamp DESC)
WHERE metric_type IN ('gauge', 'counter');

-- Grant permissions to spire role if it exists
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'spire') THEN
        -- Permissions already granted at table level, no action needed
        NULL;
    END IF;
END $$;

-- Add comments explaining the columns
COMMENT ON COLUMN otel_metrics.metric_name IS 'Name/identifier for gauge and counter metrics (e.g., "cpu_usage", "memory_bytes")';
COMMENT ON COLUMN otel_metrics.value IS 'Numeric value for gauge and counter metrics';
