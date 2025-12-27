defmodule ServiceRadar.Repo.Migrations.CreateOtelTablesFromGo do
  @moduledoc """
  Creates otel_metrics and otel_traces tables matching the Go schema exactly.
  These are TimescaleDB hypertables with composite primary keys.

  This migration drops any Ash-created tables with conflicting schemas
  and recreates them with the proper Go schema.
  """

  use Ecto.Migration

  def up do
    # Enable TimescaleDB extension
    execute "CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE"

    # Drop any Ash-created otel tables with wrong schema
    execute "DROP TABLE IF EXISTS otel_metrics CASCADE"
    execute "DROP TABLE IF EXISTS otel_traces CASCADE"
    execute "DROP TABLE IF EXISTS otel_trace_summaries CASCADE"

    # Create otel_metrics table matching Go schema exactly
    execute """
    CREATE TABLE IF NOT EXISTS otel_metrics (
        timestamp           TIMESTAMPTZ       NOT NULL,
        trace_id            TEXT,
        span_id             TEXT,
        service_name        TEXT,
        span_name           TEXT,
        span_kind           TEXT,
        duration_ms         DOUBLE PRECISION,
        duration_seconds    DOUBLE PRECISION,
        metric_type         TEXT,
        http_method         TEXT,
        http_route          TEXT,
        http_status_code    TEXT,
        grpc_service        TEXT,
        grpc_method         TEXT,
        grpc_status_code    TEXT,
        is_slow             BOOLEAN,
        component           TEXT,
        level               TEXT,
        unit                TEXT,
        created_at          TIMESTAMPTZ       NOT NULL DEFAULT now(),
        PRIMARY KEY (timestamp, span_name, service_name, span_id)
    )
    """

    # Create TimescaleDB hypertable
    execute "SELECT create_hypertable('otel_metrics','timestamp', if_not_exists => TRUE)"

    # Create indexes
    execute "CREATE INDEX IF NOT EXISTS idx_otel_metrics_service_time ON otel_metrics (service_name, timestamp DESC)"
    execute "CREATE INDEX IF NOT EXISTS idx_otel_metrics_component ON otel_metrics (component)"
    execute "CREATE INDEX IF NOT EXISTS idx_otel_metrics_unit ON otel_metrics (unit)"

    # Create otel_traces table matching Go schema
    execute """
    CREATE TABLE IF NOT EXISTS otel_traces (
        timestamp           TIMESTAMPTZ   NOT NULL,
        trace_id            TEXT,
        span_id             TEXT,
        parent_span_id      TEXT,
        name                TEXT,
        kind                INTEGER,
        start_time_unix_nano BIGINT,
        end_time_unix_nano  BIGINT,
        service_name        TEXT,
        service_version     TEXT,
        service_instance    TEXT,
        scope_name          TEXT,
        scope_version       TEXT,
        status_code         INTEGER,
        status_message      TEXT,
        attributes          TEXT,
        resource_attributes TEXT,
        events              TEXT,
        links               TEXT,
        created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
        PRIMARY KEY (timestamp, trace_id, span_id)
    )
    """

    # Create TimescaleDB hypertable for traces
    execute "SELECT create_hypertable('otel_traces','timestamp', if_not_exists => TRUE)"

    # Create indexes for traces
    execute "CREATE INDEX IF NOT EXISTS idx_otel_traces_trace_id ON otel_traces (trace_id)"
    execute "CREATE INDEX IF NOT EXISTS idx_otel_traces_service_time ON otel_traces (service_name, timestamp DESC)"

    # Create otel_trace_summaries materialized view
    execute """
    CREATE MATERIALIZED VIEW IF NOT EXISTS otel_trace_summaries AS
    SELECT
        trace_id,
        max(timestamp) AS timestamp,
        max(span_id) FILTER (WHERE coalesce(parent_span_id, '') = '') AS root_span_id,
        max(name) FILTER (WHERE coalesce(parent_span_id, '') = '') AS root_span_name,
        max(service_name) FILTER (WHERE coalesce(parent_span_id, '') = '') AS root_service_name,
        max(kind) FILTER (WHERE coalesce(parent_span_id, '') = '') AS root_span_kind,
        min(start_time_unix_nano) AS start_time_unix_nano,
        max(end_time_unix_nano) AS end_time_unix_nano,
        greatest(0, coalesce(
            (max(end_time_unix_nano) - min(start_time_unix_nano))::double precision / 1000000.0,
            0
        )) AS duration_ms,
        max(status_code) FILTER (WHERE coalesce(parent_span_id, '') = '') AS status_code,
        max(status_message) FILTER (WHERE coalesce(parent_span_id, '') = '') AS status_message,
        array_agg(DISTINCT service_name) FILTER (WHERE service_name IS NOT NULL) AS service_set,
        count(*) AS span_count,
        sum(CASE WHEN coalesce(status_code, 0) != 1 THEN 1 ELSE 0 END)::bigint AS error_count
    FROM otel_traces
    WHERE timestamp > NOW() - INTERVAL '7 days'
      AND trace_id IS NOT NULL
    GROUP BY trace_id
    """

    # Create indexes for the materialized view
    execute "CREATE UNIQUE INDEX IF NOT EXISTS idx_trace_summaries_trace_id ON otel_trace_summaries (trace_id)"
    execute "CREATE INDEX IF NOT EXISTS idx_trace_summaries_timestamp ON otel_trace_summaries (timestamp DESC)"
    execute "CREATE INDEX IF NOT EXISTS idx_trace_summaries_service_timestamp ON otel_trace_summaries (root_service_name, timestamp DESC)"

    # Create otel_metrics_hourly_stats continuous aggregation
    execute """
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
    WITH NO DATA
    """

    # Add refresh policy for the continuous aggregation
    execute """
    SELECT add_continuous_aggregate_policy('otel_metrics_hourly_stats',
        start_offset => INTERVAL '3 hours',
        end_offset => INTERVAL '1 hour',
        schedule_interval => INTERVAL '15 minutes',
        if_not_exists => TRUE
    )
    """

    # Create indexes on the continuous aggregation
    execute "CREATE INDEX IF NOT EXISTS idx_otel_metrics_hourly_stats_bucket ON otel_metrics_hourly_stats (bucket DESC)"
    execute "CREATE INDEX IF NOT EXISTS idx_otel_metrics_hourly_stats_service_bucket ON otel_metrics_hourly_stats (service_name, bucket DESC)"
  end

  def down do
    execute "DROP MATERIALIZED VIEW IF EXISTS otel_metrics_hourly_stats CASCADE"
    execute "DROP MATERIALIZED VIEW IF EXISTS otel_trace_summaries CASCADE"
    execute "DROP TABLE IF EXISTS otel_traces CASCADE"
    execute "DROP TABLE IF EXISTS otel_metrics CASCADE"
  end
end
