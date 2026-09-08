defmodule ServiceRadar.Repo.Migrations.CreateOtelMetricPoints do
  @moduledoc """
  Dedicated store for real OTLP metric data points (sum/gauge/histogram),
  distinct from the span-derived samples in `otel_metrics`. Keyed by
  metric identity (timestamp, metric_name, service_name, attributes_hash)
  so the metrics pane can compute rates over consecutive points and render
  histogram buckets.
  """
  use Ecto.Migration

  # serviceradar:allow-startup-maintenance - add_retention_policy only registers a background
  # retention job on the freshly-created (empty) otel_metric_points hypertable; no synchronous
  # data maintenance runs on the first-boot path.

  @disable_ddl_transaction true
  @disable_migration_lock true

  @retention_env "SERVICERADAR_OTEL_METRIC_POINTS_RETENTION_DAYS"
  @retention_default 30
  @chunk_env "SERVICERADAR_OTEL_METRIC_POINTS_CHUNK_INTERVAL_HOURS"
  @chunk_default 6

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS #{schema()}.otel_metric_points (
      timestamp        TIMESTAMPTZ NOT NULL,
      metric_name      TEXT NOT NULL,
      metric_type      TEXT,
      unit             TEXT,
      temporality      TEXT,
      is_monotonic     BOOLEAN,
      service_name     TEXT NOT NULL DEFAULT '',
      attributes       TEXT,
      attributes_hash  TEXT NOT NULL,
      value            DOUBLE PRECISION,
      count            BIGINT,
      sum              DOUBLE PRECISION,
      bucket_counts    TEXT,
      explicit_bounds  TEXT,
      created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY (timestamp, metric_name, service_name, attributes_hash)
    )
    """)

    execute("""
    DO $$
    DECLARE
      ts_schema text;
      table_ident text;
    BEGIN
      table_ident := format('%I.%I', '#{schema()}', 'otel_metric_points');

      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NULL THEN
        RAISE NOTICE 'TimescaleDB not available; otel_metric_points stays a plain table';
        RETURN;
      END IF;

      EXECUTE format(
        'SELECT %I.create_hypertable(%L::regclass, %L::name, '
        'chunk_time_interval => INTERVAL ''#{chunk_hours()} hours'', '
        'if_not_exists => true, migrate_data => true)',
        ts_schema,
        table_ident,
        'timestamp'
      );

      BEGIN
        EXECUTE format(
          'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''#{retention_days()} days'', if_not_exists => true)',
          ts_schema,
          table_ident
        );
      EXCEPTION
        WHEN others THEN
          NULL;
      END;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not configure otel_metric_points hypertable: %', SQLERRM;
    END;
    $$;
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_otel_metric_points_name_time
    ON #{schema()}.otel_metric_points (metric_name, timestamp DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_otel_metric_points_service_time
    ON #{schema()}.otel_metric_points (service_name, timestamp DESC)
    """)
  end

  def down do
    execute("DROP TABLE IF EXISTS #{schema()}.otel_metric_points CASCADE")
  end

  defp retention_days, do: configured_positive_integer(@retention_env, @retention_default)
  defp chunk_hours, do: configured_positive_integer(@chunk_env, @chunk_default)

  defp configured_positive_integer(env_name, default) do
    case System.get_env(env_name) do
      nil ->
        default

      "" ->
        default

      value ->
        case Integer.parse(value) do
          {int, ""} when int > 0 -> int
          _ -> default
        end
    end
  end

  defp schema, do: prefix() || "platform"
end
