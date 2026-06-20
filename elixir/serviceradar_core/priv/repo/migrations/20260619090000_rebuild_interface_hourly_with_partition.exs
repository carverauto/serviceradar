defmodule ServiceRadar.Repo.Migrations.RebuildInterfaceHourlyWithPartition do
  @moduledoc """
  Rebuilds the interface hourly CAGG with partition in the rollup identity.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @view "platform.timeseries_metrics_interface_hourly"
  @retention_interval "395 days"
  @refresh_start_offset "32 days"
  @refresh_end_offset "10 minutes"
  @refresh_interval "10 minutes"

  def up do
    remove_policy()
    execute("DROP MATERIALIZED VIEW IF EXISTS #{@view}")
    create_view(include_partition?: true)
    create_indexes(include_partition?: true)
    configure_policy()
  end

  def down do
    remove_policy()
    execute("DROP MATERIALIZED VIEW IF EXISTS #{@view}")
    create_view(include_partition?: false)
    create_indexes(include_partition?: false)
    configure_policy()
  end

  defp create_view(include_partition?: true) do
    execute("""
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{@view}
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('1 hour', timestamp) AS bucket,
      partition,
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
    GROUP BY 1, 2, 3, 4, 5, 6, 7, 8
    WITH NO DATA
    """)
  end

  defp create_view(include_partition?: false) do
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
  end

  defp create_indexes(include_partition?: true) do
    execute("""
    CREATE INDEX IF NOT EXISTS idx_timeseries_metrics_interface_hourly_bucket_device_if_metric
    ON #{@view} (bucket DESC, partition, device_id, if_index, metric_type, metric_name)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_timeseries_metrics_interface_hourly_target_if_metric
    ON #{@view} (partition, target_device_ip, if_index, metric_type, metric_name, bucket DESC)
    WHERE target_device_ip IS NOT NULL
    """)
  end

  defp create_indexes(include_partition?: false) do
    execute("""
    CREATE INDEX IF NOT EXISTS idx_timeseries_metrics_interface_hourly_bucket_device_if_metric
    ON #{@view} (bucket DESC, device_id, if_index, metric_type, metric_name)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_timeseries_metrics_interface_hourly_target_if_metric
    ON #{@view} (target_device_ip, if_index, metric_type, metric_name, bucket DESC)
    WHERE target_device_ip IS NOT NULL
    """)
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
          'SELECT %I.remove_continuous_aggregate_policy(%L::regclass, if_exists => true)',
          ts_schema,
          '#{@view}'
        );
      EXCEPTION
        WHEN others THEN
          NULL;
      END;

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
    END;
    $$;
    """)
  end
end
