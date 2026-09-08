defmodule ServiceRadar.Repo.Migrations.CreateTimeseriesMetricsInterfaceHourly do
  @moduledoc """
  Creates an interface-keyed hourly CAGG for SNMP/interface capacity planning.
  """
  use Ecto.Migration

  # serviceradar:allow-startup-maintenance - interface-hourly CAGG: the source hypertable
  # is empty on first boot so the create/refresh are no-ops; the one-time refresh is bounded
  # to the retention window and the continuous-aggregate/retention policies only register
  # background jobs.

  @disable_ddl_transaction true
  @disable_migration_lock true

  @view "platform.timeseries_metrics_interface_hourly"
  @retention_interval "395 days"
  @refresh_start_offset "32 days"
  @refresh_end_offset "10 minutes"
  @refresh_interval "10 minutes"

  def up do
    execute("""
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{@view}
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('1 hour', timestamp) AS bucket,
      device_id,
      target_device_ip,
      if_index,
      metric_type,
      metric_name,
      series_key,
      AVG(value)::float8 AS avg_value,
      MIN(value)::float8 AS min_value,
      MAX(value)::float8 AS max_value,
      GREATEST(MAX(value) - MIN(value), 0)::float8 AS delta_value,
      EXTRACT(EPOCH FROM (MAX(timestamp) - MIN(timestamp)))::float8 AS duration_seconds,
      CASE
        WHEN MAX(timestamp) > MIN(timestamp) AND MAX(value) >= MIN(value)
        THEN ((MAX(value) - MIN(value)) / EXTRACT(EPOCH FROM (MAX(timestamp) - MIN(timestamp))))::float8
        ELSE NULL
      END AS avg_rate_per_second,
      COUNT(*)::bigint AS sample_count
    FROM platform.timeseries_metrics
    WHERE if_index IS NOT NULL
      AND COALESCE(metadata->>'kind', metadata->>'metric_type') IN ('sum', 'counter')
      AND metadata->>'temporality' = 'cumulative'
      AND LOWER(COALESCE(metadata->>'is_monotonic', 'false')) IN ('true', '1')
      AND metadata ? 'raw_value'
    GROUP BY 1, 2, 3, 4, 5, 6, 7
    WITH NO DATA
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_timeseries_metrics_interface_hourly_bucket_device_if_metric
    ON #{@view} (bucket DESC, device_id, if_index, metric_type, metric_name)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_timeseries_metrics_interface_hourly_target_if_metric
    ON #{@view} (target_device_ip, if_index, metric_type, metric_name, bucket DESC)
    WHERE target_device_ip IS NOT NULL
    """)

    configure_policy()
  end

  def down do
    remove_policy()
    execute("DROP MATERIALIZED VIEW IF EXISTS #{@view}")
  end

  defp configure_policy do
    execute("""
    DO $$
    DECLARE
      ts_schema text;
    BEGIN
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NULL THEN
        RETURN;
      END IF;

      BEGIN
        EXECUTE format(
          'SELECT %I.add_continuous_aggregate_policy(%L::regclass, '
          'start_offset => INTERVAL ''#{@refresh_start_offset}'', '
          'end_offset => INTERVAL ''#{@refresh_end_offset}'', '
          'schedule_interval => INTERVAL ''#{@refresh_interval}'')',
          ts_schema,
          '#{@view}'
        );
      EXCEPTION
        WHEN others THEN
          NULL;
      END;

      BEGIN
        EXECUTE format(
          'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''#{@retention_interval}'', if_not_exists => true)',
          ts_schema,
          '#{@view}'
        );
      EXCEPTION
        WHEN others THEN
          NULL;
      END;

      BEGIN
        EXECUTE format(
          'CALL %I.refresh_continuous_aggregate(%L::regclass, NOW() - INTERVAL ''#{@retention_interval}'', NOW())',
          ts_schema,
          '#{@view}'
        );
      EXCEPTION
        WHEN others THEN
          NULL;
      END;
    END;
    $$;
    """)
  end

  defp remove_policy do
    execute("""
    DO $$
    DECLARE
      ts_schema text;
    BEGIN
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NULL THEN
        RETURN;
      END IF;

      BEGIN
        EXECUTE format(
          'SELECT %I.remove_retention_policy(%L::regclass, if_exists => true)',
          ts_schema,
          '#{@view}'
        );
      EXCEPTION
        WHEN others THEN
          NULL;
      END;

      BEGIN
        EXECUTE format(
          'SELECT %I.remove_continuous_aggregate_policy(%L::regclass)',
          ts_schema,
          '#{@view}'
        );
      EXCEPTION
        WHEN others THEN
          NULL;
      END;
    END;
    $$;
    """)
  end
end
