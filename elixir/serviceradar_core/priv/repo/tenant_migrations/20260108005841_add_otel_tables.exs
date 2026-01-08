defmodule ServiceRadar.Repo.TenantMigrations.AddOtelTables do
  @moduledoc """
  Creates OTEL observability tables in tenant schemas.

  These tables use TimescaleDB hypertables for time-series data with composite
  primary keys. Ash resources have `migrate? false` so we manage these manually.
  """

  use Ecto.Migration

  def up do
    schema = prefix() || "public"

    # Drop existing logs table if it exists (may have incompatible schema)
    # This is safe because logs are append-only telemetry data
    execute "DROP TABLE IF EXISTS #{schema}.logs CASCADE"

    # Create logs table as TimescaleDB hypertable
    # Composite primary key (timestamp, id) required for hypertable partitioning
    execute """
    CREATE TABLE #{schema}.logs (
      timestamp           TIMESTAMPTZ   NOT NULL,
      id                  UUID          NOT NULL DEFAULT gen_random_uuid(),
      trace_id            TEXT,
      span_id             TEXT,
      severity_text       TEXT,
      severity_number     INTEGER,
      body                TEXT,
      service_name        TEXT,
      service_version     TEXT,
      service_instance    TEXT,
      scope_name          TEXT,
      scope_version       TEXT,
      attributes          JSONB         DEFAULT '{}'::jsonb,
      resource_attributes JSONB         DEFAULT '{}'::jsonb,
      tenant_id           UUID          NOT NULL,
      created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
      PRIMARY KEY (timestamp, id)
    )
    """

    execute "SELECT create_hypertable('#{schema}.logs', 'timestamp', if_not_exists => TRUE)"

    execute "CREATE INDEX IF NOT EXISTS idx_logs_service_time ON #{schema}.logs (service_name, timestamp DESC)"
    execute "CREATE INDEX IF NOT EXISTS idx_logs_trace_id ON #{schema}.logs (trace_id) WHERE trace_id IS NOT NULL"
    execute "CREATE INDEX IF NOT EXISTS idx_logs_severity ON #{schema}.logs (severity_number, timestamp DESC)"
    execute "CREATE INDEX IF NOT EXISTS idx_logs_tenant ON #{schema}.logs (tenant_id, timestamp DESC)"

    # Create otel_metrics table (hypertable)
    execute """
    CREATE TABLE IF NOT EXISTS #{schema}.otel_metrics (
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

    execute "SELECT create_hypertable('#{schema}.otel_metrics', 'timestamp', if_not_exists => TRUE)"

    execute """
    CREATE INDEX IF NOT EXISTS idx_otel_metrics_service_time
    ON #{schema}.otel_metrics (service_name, timestamp DESC)
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_otel_metrics_component
    ON #{schema}.otel_metrics (component)
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_otel_metrics_unit
    ON #{schema}.otel_metrics (unit)
    """

    # Create otel_traces table (hypertable)
    execute """
    CREATE TABLE IF NOT EXISTS #{schema}.otel_traces (
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

    execute "SELECT create_hypertable('#{schema}.otel_traces', 'timestamp', if_not_exists => TRUE)"

    execute """
    CREATE INDEX IF NOT EXISTS idx_otel_traces_trace_id
    ON #{schema}.otel_traces (trace_id)
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_otel_traces_service_time
    ON #{schema}.otel_traces (service_name, timestamp DESC)
    """

    # Create otel_trace_summaries materialized view
    execute """
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{schema}.otel_trace_summaries AS
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
    FROM #{schema}.otel_traces
    WHERE timestamp > NOW() - INTERVAL '7 days'
      AND trace_id IS NOT NULL
    GROUP BY trace_id
    """

    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS idx_trace_summaries_trace_id
    ON #{schema}.otel_trace_summaries (trace_id)
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_trace_summaries_timestamp
    ON #{schema}.otel_trace_summaries (timestamp DESC)
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_trace_summaries_service_timestamp
    ON #{schema}.otel_trace_summaries (root_service_name, timestamp DESC)
    """
  end

  def down do
    schema = prefix() || "public"

    execute "DROP MATERIALIZED VIEW IF EXISTS #{schema}.otel_trace_summaries CASCADE"
    execute "DROP TABLE IF EXISTS #{schema}.otel_traces CASCADE"
    execute "DROP TABLE IF EXISTS #{schema}.otel_metrics CASCADE"
    execute "DROP TABLE IF EXISTS #{schema}.logs CASCADE"
  end
end
