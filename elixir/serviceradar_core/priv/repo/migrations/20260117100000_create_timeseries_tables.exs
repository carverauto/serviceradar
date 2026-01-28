defmodule ServiceRadar.Repo.Migrations.CreateTimeseriesTables do
  @moduledoc """
  Creates time-series tables for SRQL queries.

  These tables store observability data (logs, traces, metrics, events) that
  SRQL queries against. They are designed as TimescaleDB hypertables but work
  as regular PostgreSQL tables if TimescaleDB is not available.

  This migration is idempotent - safe to run multiple times.
  """
  use Ecto.Migration

  @timeseries_tables [
    "events",
    "logs",
    "service_status",
    "otel_traces",
    "otel_metrics",
    "timeseries_metrics",
    "cpu_metrics",
    "disk_metrics",
    "memory_metrics",
    "process_metrics",
    "device_updates",
    "otel_metrics_hourly_stats"
  ]

  def up do
    # Create events table (CloudEvents-style activity log)
    execute("""
    CREATE TABLE IF NOT EXISTS events (
      event_timestamp TIMESTAMPTZ NOT NULL,
      specversion     TEXT,
      id              TEXT        NOT NULL,
      source          TEXT,
      type            TEXT,
      datacontenttype TEXT,
      subject         TEXT,
      remote_addr     TEXT,
      host            TEXT,
      level           INT,
      severity        TEXT,
      short_message   TEXT,
      version         TEXT,
      raw_data        TEXT,
      created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY (event_timestamp, id)
    )
    """)

    # Create logs table (OpenTelemetry logs)
    execute("""
    CREATE TABLE IF NOT EXISTS logs (
      timestamp           TIMESTAMPTZ NOT NULL,
      id                  UUID        NOT NULL DEFAULT gen_random_uuid(),
      trace_id            TEXT,
      span_id             TEXT,
      severity_text       TEXT,
      severity_number     INT,
      body                TEXT,
      service_name        TEXT,
      service_version     TEXT,
      service_instance    TEXT,
      scope_name          TEXT,
      scope_version       TEXT,
      attributes          TEXT,
      resource_attributes TEXT,
      created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY (timestamp, id)
    )
    """)

    # Create service_status table
    execute("""
    CREATE TABLE IF NOT EXISTS service_status (
      timestamp    TIMESTAMPTZ NOT NULL,
      gateway_id   TEXT        NOT NULL,
      agent_id     TEXT,
      service_name TEXT        NOT NULL,
      service_type TEXT,
      available    BOOLEAN     NOT NULL,
      message      TEXT,
      details      TEXT,
      partition    TEXT,
      created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY (timestamp, gateway_id, service_name)
    )
    """)

    # Create otel_traces table (OpenTelemetry traces/spans)
    execute("""
    CREATE TABLE IF NOT EXISTS otel_traces (
      timestamp            TIMESTAMPTZ NOT NULL,
      trace_id             TEXT,
      span_id              TEXT        NOT NULL,
      parent_span_id       TEXT,
      name                 TEXT,
      kind                 INT,
      start_time_unix_nano BIGINT,
      end_time_unix_nano   BIGINT,
      service_name         TEXT,
      service_version      TEXT,
      service_instance     TEXT,
      scope_name           TEXT,
      scope_version        TEXT,
      status_code          INT,
      status_message       TEXT,
      attributes           TEXT,
      resource_attributes  TEXT,
      events               TEXT,
      links                TEXT,
      created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY (timestamp, trace_id, span_id)
    )
    """)

    # Create otel_metrics table (OpenTelemetry metrics derived from traces)
    execute("""
    CREATE TABLE IF NOT EXISTS otel_metrics (
      timestamp        TIMESTAMPTZ NOT NULL,
      trace_id         TEXT,
      span_id          TEXT,
      service_name     TEXT,
      span_name        TEXT,
      span_kind        TEXT,
      duration_ms      FLOAT8,
      duration_seconds FLOAT8,
      metric_type      TEXT,
      http_method      TEXT,
      http_route       TEXT,
      http_status_code TEXT,
      grpc_service     TEXT,
      grpc_method      TEXT,
      grpc_status_code TEXT,
      is_slow          BOOLEAN,
      component        TEXT,
      level            TEXT,
      unit             TEXT,
      created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY (timestamp, span_name, service_name, span_id)
    )
    """)

    # Create timeseries_metrics table (generic time-series metrics)
    execute("""
    CREATE TABLE IF NOT EXISTS timeseries_metrics (
      timestamp        TIMESTAMPTZ NOT NULL,
      gateway_id       TEXT        NOT NULL,
      agent_id         TEXT,
      metric_name      TEXT        NOT NULL,
      metric_type      TEXT        NOT NULL,
      device_id        TEXT,
      value            FLOAT8      NOT NULL,
      unit             TEXT,
      tags             JSONB,
      partition        TEXT,
      scale            FLOAT8,
      is_delta         BOOLEAN,
      target_device_ip TEXT,
      if_index         INT,
      metadata         JSONB,
      created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY (timestamp, gateway_id, metric_name)
    )
    """)

    # Create cpu_metrics table
    execute("""
    CREATE TABLE IF NOT EXISTS cpu_metrics (
      timestamp     TIMESTAMPTZ NOT NULL,
      gateway_id    TEXT        NOT NULL,
      agent_id      TEXT,
      host_id       TEXT,
      core_id       INT         NOT NULL DEFAULT 0,
      usage_percent FLOAT8,
      frequency_hz  FLOAT8,
      label         TEXT,
      cluster       TEXT,
      device_id     TEXT,
      partition     TEXT,
      created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY (timestamp, gateway_id, core_id)
    )
    """)

    # Create disk_metrics table
    execute("""
    CREATE TABLE IF NOT EXISTS disk_metrics (
      timestamp       TIMESTAMPTZ NOT NULL,
      gateway_id      TEXT        NOT NULL DEFAULT '',
      agent_id        TEXT,
      host_id         TEXT,
      mount_point     TEXT        NOT NULL DEFAULT '/',
      device_name     TEXT,
      total_bytes     BIGINT,
      used_bytes      BIGINT,
      available_bytes BIGINT,
      usage_percent   FLOAT8,
      device_id       TEXT,
      partition       TEXT,
      created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY (timestamp, gateway_id, mount_point)
    )
    """)

    # Create memory_metrics table
    execute("""
    CREATE TABLE IF NOT EXISTS memory_metrics (
      timestamp       TIMESTAMPTZ NOT NULL,
      gateway_id      TEXT        NOT NULL DEFAULT '',
      agent_id        TEXT,
      host_id         TEXT,
      total_bytes     BIGINT,
      used_bytes      BIGINT,
      available_bytes BIGINT,
      usage_percent   FLOAT8,
      device_id       TEXT,
      partition       TEXT,
      created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY (timestamp, gateway_id)
    )
    """)

    # Create process_metrics table
    execute("""
    CREATE TABLE IF NOT EXISTS process_metrics (
      timestamp    TIMESTAMPTZ NOT NULL,
      gateway_id   TEXT        NOT NULL DEFAULT '',
      agent_id     TEXT,
      host_id      TEXT,
      pid          INT         NOT NULL DEFAULT 0,
      name         TEXT,
      cpu_usage    REAL,
      memory_usage BIGINT,
      status       TEXT,
      start_time   TEXT,
      device_id    TEXT,
      partition    TEXT,
      created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY (timestamp, gateway_id, pid)
    )
    """)

    # Create device_updates table (device history log)
    execute("""
    CREATE TABLE IF NOT EXISTS device_updates (
      observed_at      TIMESTAMPTZ NOT NULL,
      agent_id         TEXT        NOT NULL DEFAULT '',
      gateway_id       TEXT        NOT NULL DEFAULT '',
      partition        TEXT        NOT NULL DEFAULT 'default',
      device_id        TEXT        NOT NULL,
      discovery_source TEXT        NOT NULL DEFAULT 'unknown',
      ip               TEXT,
      mac              TEXT,
      hostname         TEXT,
      available        BOOLEAN,
      metadata         JSONB,
      created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY (observed_at, device_id)
    )
    """)

    # Create otel_metrics_hourly_stats table (pre-computed hourly stats for analytics)
    execute("""
    CREATE TABLE IF NOT EXISTS otel_metrics_hourly_stats (
      bucket           TIMESTAMPTZ NOT NULL,
      service_name     TEXT        NOT NULL DEFAULT '',
      total_count      BIGINT      NOT NULL DEFAULT 0,
      error_count      BIGINT      NOT NULL DEFAULT 0,
      slow_count       BIGINT      NOT NULL DEFAULT 0,
      http_4xx_count   BIGINT      NOT NULL DEFAULT 0,
      http_5xx_count   BIGINT      NOT NULL DEFAULT 0,
      grpc_error_count BIGINT      NOT NULL DEFAULT 0,
      avg_duration_ms  FLOAT8      NOT NULL DEFAULT 0,
      p95_duration_ms  FLOAT8,
      max_duration_ms  FLOAT8,
      PRIMARY KEY (bucket, service_name)
    )
    """)

    # Ensure tables are owned by the current user (handles case where tables
    # were created by a different user, e.g., postgres vs serviceradar)
    @timeseries_tables
    |> Enum.each(&ensure_table_ownership/1)

    # Try to convert tables to TimescaleDB hypertables if available
    # Each call is wrapped in its own exception handler to be idempotent
    maybe_create_hypertable("events", "event_timestamp")
    maybe_create_hypertable("logs", "timestamp")
    maybe_create_hypertable("service_status", "timestamp")
    maybe_create_hypertable("otel_traces", "timestamp")
    maybe_create_hypertable("otel_metrics", "timestamp")
    maybe_create_hypertable("timeseries_metrics", "timestamp")
    maybe_create_hypertable("cpu_metrics", "timestamp")
    maybe_create_hypertable("disk_metrics", "timestamp")
    maybe_create_hypertable("memory_metrics", "timestamp")
    maybe_create_hypertable("process_metrics", "timestamp")
    maybe_create_hypertable("device_updates", "observed_at")
    maybe_create_hypertable("otel_metrics_hourly_stats", "bucket")

    # Create indexes for common query patterns
    execute(
      "CREATE INDEX IF NOT EXISTS idx_events_timestamp ON #{prefix()}.events (event_timestamp DESC)"
    )

    execute("CREATE INDEX IF NOT EXISTS idx_events_source ON #{prefix()}.events (source)")
    execute("CREATE INDEX IF NOT EXISTS idx_events_severity ON #{prefix()}.events (severity)")

    execute("CREATE INDEX IF NOT EXISTS idx_logs_timestamp ON #{prefix()}.logs (timestamp DESC)")
    execute("CREATE INDEX IF NOT EXISTS idx_logs_service ON #{prefix()}.logs (service_name)")
    execute("CREATE INDEX IF NOT EXISTS idx_logs_severity ON #{prefix()}.logs (severity_text)")

    execute(
      "CREATE INDEX IF NOT EXISTS idx_logs_trace_id ON #{prefix()}.logs (trace_id) WHERE trace_id IS NOT NULL"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS idx_service_status_timestamp ON #{prefix()}.service_status (timestamp DESC)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS idx_service_status_gateway ON #{prefix()}.service_status (gateway_id)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS idx_otel_traces_timestamp ON #{prefix()}.otel_traces (timestamp DESC)"
    )

    execute("CREATE INDEX IF NOT EXISTS idx_otel_traces_trace_id ON #{prefix()}.otel_traces (trace_id)")

    execute(
      "CREATE INDEX IF NOT EXISTS idx_otel_traces_service ON #{prefix()}.otel_traces (service_name)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS idx_otel_metrics_timestamp ON #{prefix()}.otel_metrics (timestamp DESC)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS idx_otel_metrics_service ON #{prefix()}.otel_metrics (service_name)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS idx_timeseries_metrics_timestamp ON #{prefix()}.timeseries_metrics (timestamp DESC)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS idx_timeseries_metrics_name ON #{prefix()}.timeseries_metrics (metric_name)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS idx_timeseries_metrics_device ON #{prefix()}.timeseries_metrics (device_id) WHERE device_id IS NOT NULL"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS idx_device_updates_device ON #{prefix()}.device_updates (device_id)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS idx_device_updates_timestamp ON #{prefix()}.device_updates (observed_at DESC)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS idx_otel_metrics_hourly_stats_bucket ON #{prefix()}.otel_metrics_hourly_stats (bucket DESC)"
    )
  end

  def down do
    # Drop indexes first
    execute("DROP INDEX IF EXISTS #{prefix()}.idx_otel_metrics_hourly_stats_bucket")
    execute("DROP INDEX IF EXISTS #{prefix()}.idx_device_updates_timestamp")
    execute("DROP INDEX IF EXISTS #{prefix()}.idx_device_updates_device")
    execute("DROP INDEX IF EXISTS #{prefix()}.idx_timeseries_metrics_device")
    execute("DROP INDEX IF EXISTS #{prefix()}.idx_timeseries_metrics_name")
    execute("DROP INDEX IF EXISTS #{prefix()}.idx_timeseries_metrics_timestamp")
    execute("DROP INDEX IF EXISTS #{prefix()}.idx_otel_metrics_service")
    execute("DROP INDEX IF EXISTS #{prefix()}.idx_otel_metrics_timestamp")
    execute("DROP INDEX IF EXISTS #{prefix()}.idx_otel_traces_service")
    execute("DROP INDEX IF EXISTS #{prefix()}.idx_otel_traces_trace_id")
    execute("DROP INDEX IF EXISTS #{prefix()}.idx_otel_traces_timestamp")
    execute("DROP INDEX IF EXISTS #{prefix()}.idx_service_status_gateway")
    execute("DROP INDEX IF EXISTS #{prefix()}.idx_service_status_timestamp")
    execute("DROP INDEX IF EXISTS #{prefix()}.idx_logs_trace_id")
    execute("DROP INDEX IF EXISTS #{prefix()}.idx_logs_severity")
    execute("DROP INDEX IF EXISTS #{prefix()}.idx_logs_service")
    execute("DROP INDEX IF EXISTS #{prefix()}.idx_logs_timestamp")
    execute("DROP INDEX IF EXISTS #{prefix()}.idx_events_severity")
    execute("DROP INDEX IF EXISTS #{prefix()}.idx_events_source")
    execute("DROP INDEX IF EXISTS #{prefix()}.idx_events_timestamp")

    # Drop tables (note: if they're hypertables, this works correctly)
    execute("DROP TABLE IF EXISTS #{prefix()}.otel_metrics_hourly_stats")
    execute("DROP TABLE IF EXISTS #{prefix()}.device_updates")
    execute("DROP TABLE IF EXISTS #{prefix()}.process_metrics")
    execute("DROP TABLE IF EXISTS #{prefix()}.memory_metrics")
    execute("DROP TABLE IF EXISTS #{prefix()}.disk_metrics")
    execute("DROP TABLE IF EXISTS #{prefix()}.cpu_metrics")
    execute("DROP TABLE IF EXISTS #{prefix()}.timeseries_metrics")
    execute("DROP TABLE IF EXISTS #{prefix()}.otel_metrics")
    execute("DROP TABLE IF EXISTS #{prefix()}.otel_traces")
    execute("DROP TABLE IF EXISTS #{prefix()}.service_status")
    execute("DROP TABLE IF EXISTS #{prefix()}.logs")
    execute("DROP TABLE IF EXISTS #{prefix()}.events")
  end

  # Helper to conditionally create hypertable (idempotent)
  defp maybe_create_hypertable(table_name, time_column) do
    # Check if TimescaleDB is available and table is not already a hypertable
    execute("""
    DO $$
    BEGIN
      -- Only try if TimescaleDB extension exists
      IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'timescaledb') THEN
        -- Only convert if not already a hypertable
        IF NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_name = '#{table_name}'
          AND hypertable_schema = '#{prefix()}'
        ) THEN
          PERFORM create_hypertable(
            '#{prefix()}.#{table_name}'::regclass,
            '#{time_column}',
            migrate_data => true,
            if_not_exists => true
          );
          RAISE NOTICE 'Created hypertable for #{table_name}';
        END IF;
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not create hypertable for #{table_name}: %', SQLERRM;
    END;
    $$;
    """)
  end

  # Helper to ensure table ownership matches current user (idempotent)
  # This handles the case where tables were created by a different user
  defp ensure_table_ownership(table_name) do
    execute("""
    DO $$
    BEGIN
      -- Only change ownership if table exists and current user is not already owner
      IF EXISTS (
        SELECT 1 FROM pg_tables
        WHERE tablename = '#{table_name}'
        AND schemaname = '#{prefix()}'
      ) THEN
        EXECUTE format('ALTER TABLE %I.%I OWNER TO CURRENT_USER', '#{prefix()}', '#{table_name}');
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not change ownership for #{table_name}: %', SQLERRM;
    END;
    $$;
    """)
  end
end
