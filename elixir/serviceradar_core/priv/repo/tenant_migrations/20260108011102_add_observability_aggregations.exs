defmodule ServiceRadar.Repo.TenantMigrations.AddObservabilityAggregations do
  @moduledoc """
  Creates TimescaleDB continuous aggregations for observability dashboard stats.

  These CAGGs provide pre-computed aggregates for dashboard stats cards,
  avoiding full table scans on raw hypertables.
  """

  use Ecto.Migration

  def up do
    schema = prefix() || "public"

    # ============================================================================
    # otel_metrics_hourly_stats - Pre-computed metrics stats
    # ============================================================================

    execute """
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{schema}.otel_metrics_hourly_stats
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
    FROM #{schema}.otel_metrics
    GROUP BY bucket, service_name, metric_type
    WITH NO DATA
    """

    execute """
    SELECT add_continuous_aggregate_policy('#{schema}.otel_metrics_hourly_stats',
      start_offset => INTERVAL '3 hours',
      end_offset => INTERVAL '1 hour',
      schedule_interval => INTERVAL '15 minutes',
      if_not_exists => TRUE
    )
    """

    execute "CREATE INDEX IF NOT EXISTS idx_otel_metrics_hourly_stats_bucket ON #{schema}.otel_metrics_hourly_stats (bucket DESC)"
    execute "CREATE INDEX IF NOT EXISTS idx_otel_metrics_hourly_stats_service_bucket ON #{schema}.otel_metrics_hourly_stats (service_name, bucket DESC)"

    # ============================================================================
    # logs_severity_stats_5m - Log severity breakdown
    # ============================================================================

    execute """
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{schema}.logs_severity_stats_5m
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
    FROM #{schema}.logs
    GROUP BY bucket, service_name
    WITH NO DATA
    """

    execute """
    SELECT add_continuous_aggregate_policy('#{schema}.logs_severity_stats_5m',
      start_offset => INTERVAL '3 hours',
      end_offset => INTERVAL '1 hour',
      schedule_interval => INTERVAL '5 minutes',
      if_not_exists => TRUE
    )
    """

    execute "CREATE INDEX IF NOT EXISTS idx_logs_severity_stats_5m_bucket ON #{schema}.logs_severity_stats_5m (bucket DESC)"
    execute "CREATE INDEX IF NOT EXISTS idx_logs_severity_stats_5m_service_bucket ON #{schema}.logs_severity_stats_5m (service_name, bucket DESC)"

    # ============================================================================
    # traces_stats_5m - Trace counts, errors, duration percentiles
    # ============================================================================

    execute """
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{schema}.traces_stats_5m
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('5 minutes', timestamp) AS bucket,
      service_name,
      COUNT(*) FILTER (WHERE parent_span_id IS NULL OR parent_span_id = '') AS total_count,
      COUNT(*) FILTER (WHERE (parent_span_id IS NULL OR parent_span_id = '') AND status_code = 2) AS error_count,
      AVG((end_time_unix_nano - start_time_unix_nano) / 1000000.0)
        FILTER (WHERE parent_span_id IS NULL OR parent_span_id = '') AS avg_duration_ms,
      PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY (end_time_unix_nano - start_time_unix_nano) / 1000000.0)
        FILTER (WHERE parent_span_id IS NULL OR parent_span_id = '') AS p95_duration_ms
    FROM #{schema}.otel_traces
    GROUP BY bucket, service_name
    WITH NO DATA
    """

    execute """
    SELECT add_continuous_aggregate_policy('#{schema}.traces_stats_5m',
      start_offset => INTERVAL '3 hours',
      end_offset => INTERVAL '1 hour',
      schedule_interval => INTERVAL '5 minutes',
      if_not_exists => TRUE
    )
    """

    execute "CREATE INDEX IF NOT EXISTS idx_traces_stats_5m_bucket ON #{schema}.traces_stats_5m (bucket DESC)"
    execute "CREATE INDEX IF NOT EXISTS idx_traces_stats_5m_service_bucket ON #{schema}.traces_stats_5m (service_name, bucket DESC)"

    # ============================================================================
    # services_availability_5m - Service availability rollups
    # ============================================================================

    execute """
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{schema}.services_availability_5m
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('5 minutes', timestamp) AS bucket,
      service_type,
      COUNT(DISTINCT (gateway_id, COALESCE(agent_id, ''), service_name)) AS total_count,
      COUNT(DISTINCT (gateway_id, COALESCE(agent_id, ''), service_name)) FILTER (WHERE available = true) AS available_count,
      COUNT(DISTINCT (gateway_id, COALESCE(agent_id, ''), service_name)) FILTER (WHERE available = false) AS unavailable_count
    FROM #{schema}.service_status
    GROUP BY bucket, service_type
    WITH NO DATA
    """

    execute """
    SELECT add_continuous_aggregate_policy('#{schema}.services_availability_5m',
      start_offset => INTERVAL '3 hours',
      end_offset => INTERVAL '1 hour',
      schedule_interval => INTERVAL '5 minutes',
      if_not_exists => TRUE
    )
    """

    execute "CREATE INDEX IF NOT EXISTS idx_services_availability_5m_bucket ON #{schema}.services_availability_5m (bucket DESC)"
    execute "CREATE INDEX IF NOT EXISTS idx_services_availability_5m_type_bucket ON #{schema}.services_availability_5m (service_type, bucket DESC)"
  end

  def down do
    schema = prefix() || "public"

    # Remove continuous aggregate policies and views
    execute "DROP MATERIALIZED VIEW IF EXISTS #{schema}.services_availability_5m CASCADE"
    execute "DROP MATERIALIZED VIEW IF EXISTS #{schema}.traces_stats_5m CASCADE"
    execute "DROP MATERIALIZED VIEW IF EXISTS #{schema}.logs_severity_stats_5m CASCADE"
    execute "DROP MATERIALIZED VIEW IF EXISTS #{schema}.otel_metrics_hourly_stats CASCADE"
  end
end
