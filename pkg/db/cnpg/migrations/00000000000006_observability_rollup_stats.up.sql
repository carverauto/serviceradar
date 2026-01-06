-- Migration: Observability rollup stats continuous aggregates
-- This migration creates CAGGs for dashboard stats cards to query pre-computed
-- aggregates instead of scanning raw hypertables.
--
-- CAGGs created:
-- 1. logs_severity_stats_5m - Log severity breakdown
-- 2. traces_stats_5m - Trace counts, errors, duration percentiles
-- 3. services_availability_5m - Service availability rollups

-- ============================================================================
-- logs_severity_stats_5m
-- Pre-computes log severity counts for dashboard stats cards
-- ============================================================================
CREATE MATERIALIZED VIEW IF NOT EXISTS logs_severity_stats_5m
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('5 minutes', timestamp) AS bucket,
    service_name,
    COUNT(*) AS total_count,
    COUNT(*) FILTER (WHERE LOWER(severity_text) IN ('fatal', 'critical', 'emergency', 'alert')) AS fatal_count,
    COUNT(*) FILTER (WHERE LOWER(severity_text) IN ('error', 'err')) AS error_count,
    COUNT(*) FILTER (WHERE LOWER(severity_text) IN ('warn', 'warning')) AS warning_count,
    COUNT(*) FILTER (WHERE LOWER(severity_text) IN ('info', 'information', 'informational', 'notice')) AS info_count,
    COUNT(*) FILTER (WHERE LOWER(severity_text) IN ('debug', 'trace')) AS debug_count
FROM logs
GROUP BY bucket, service_name
WITH NO DATA;

-- Refresh policy: every 5 minutes, covering 3 hours back with 1 hour end offset
SELECT add_continuous_aggregate_policy('logs_severity_stats_5m',
    start_offset => INTERVAL '3 hours',
    end_offset => INTERVAL '1 hour',
    schedule_interval => INTERVAL '5 minutes',
    if_not_exists => TRUE
);

-- Indexes for efficient time-range and service filtering
CREATE INDEX IF NOT EXISTS idx_logs_severity_stats_5m_bucket
ON logs_severity_stats_5m (bucket DESC);

CREATE INDEX IF NOT EXISTS idx_logs_severity_stats_5m_service_bucket
ON logs_severity_stats_5m (service_name, bucket DESC);

COMMENT ON MATERIALIZED VIEW logs_severity_stats_5m IS
'Pre-computed log severity counts in 5-minute buckets for dashboard stats cards.
Severity normalization handles case variations and common synonyms.';

-- ============================================================================
-- traces_stats_5m
-- Pre-computes trace statistics from root spans for dashboard stats cards
-- ============================================================================
CREATE MATERIALIZED VIEW IF NOT EXISTS traces_stats_5m
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('5 minutes', timestamp) AS bucket,
    service_name,
    -- Count only root spans (no parent)
    COUNT(*) FILTER (WHERE parent_span_id IS NULL OR parent_span_id = '') AS total_count,
    -- Error count (status_code = 2 means ERROR in OpenTelemetry)
    COUNT(*) FILTER (WHERE (parent_span_id IS NULL OR parent_span_id = '') AND status_code = 2) AS error_count,
    -- Duration stats in milliseconds (convert from nanoseconds)
    AVG((end_time_unix_nano - start_time_unix_nano) / 1000000.0)
        FILTER (WHERE parent_span_id IS NULL OR parent_span_id = '') AS avg_duration_ms,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY (end_time_unix_nano - start_time_unix_nano) / 1000000.0)
        FILTER (WHERE parent_span_id IS NULL OR parent_span_id = '') AS p95_duration_ms
FROM otel_traces
GROUP BY bucket, service_name
WITH NO DATA;

-- Refresh policy: every 5 minutes
SELECT add_continuous_aggregate_policy('traces_stats_5m',
    start_offset => INTERVAL '3 hours',
    end_offset => INTERVAL '1 hour',
    schedule_interval => INTERVAL '5 minutes',
    if_not_exists => TRUE
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_traces_stats_5m_bucket
ON traces_stats_5m (bucket DESC);

CREATE INDEX IF NOT EXISTS idx_traces_stats_5m_service_bucket
ON traces_stats_5m (service_name, bucket DESC);

COMMENT ON MATERIALIZED VIEW traces_stats_5m IS
'Pre-computed trace statistics from root spans in 5-minute buckets.
Only root spans (parent_span_id IS NULL) are counted to avoid double-counting.
Duration is computed in milliseconds from nanosecond timestamps.';

-- ============================================================================
-- services_availability_5m
-- Pre-computes service availability counts for dashboard stats cards
-- ============================================================================
CREATE MATERIALIZED VIEW IF NOT EXISTS services_availability_5m
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('5 minutes', timestamp) AS bucket,
    service_type,
    -- Count unique service instances (identified by gateway_id, agent_id, service_name)
    COUNT(DISTINCT (gateway_id, COALESCE(agent_id, ''), service_name)) AS total_count,
    COUNT(DISTINCT (gateway_id, COALESCE(agent_id, ''), service_name)) FILTER (WHERE available = true) AS available_count,
    COUNT(DISTINCT (gateway_id, COALESCE(agent_id, ''), service_name)) FILTER (WHERE available = false) AS unavailable_count
FROM service_status
GROUP BY bucket, service_type
WITH NO DATA;

-- Refresh policy: every 5 minutes
SELECT add_continuous_aggregate_policy('services_availability_5m',
    start_offset => INTERVAL '3 hours',
    end_offset => INTERVAL '1 hour',
    schedule_interval => INTERVAL '5 minutes',
    if_not_exists => TRUE
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_services_availability_5m_bucket
ON services_availability_5m (bucket DESC);

CREATE INDEX IF NOT EXISTS idx_services_availability_5m_type_bucket
ON services_availability_5m (service_type, bucket DESC);

COMMENT ON MATERIALIZED VIEW services_availability_5m IS
'Pre-computed service availability counts in 5-minute buckets.
Unique services are identified by (gateway_id, agent_id, service_name) tuple.
Counts are broken down by service_type for filtering.';

-- ============================================================================
-- Role grants
-- ============================================================================
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'spire') THEN
        GRANT SELECT ON TABLE logs_severity_stats_5m TO spire;
        GRANT SELECT ON TABLE traces_stats_5m TO spire;
        GRANT SELECT ON TABLE services_availability_5m TO spire;
    END IF;
END $$;
