defmodule ServiceRadar.Repo.Migrations.CreateTimeseriesMetricsDiskHourly do
  @moduledoc """
  Hourly continuous aggregate of sysmon disk gauges keyed by device, series and
  mount point.

  `timeseries_metrics_hourly` groups by device and metric only, so every mount
  point on a host is averaged into one value and a filling data volume hides
  behind a flat root filesystem. This aggregate keeps `tags->>'mount_point'`
  in the rollup identity so capacity forecasting can project each mount.

  The refresh window is clamped inside the raw table's seven-day retention, the
  same guard `20260812020000_repair_cagg_refresh_windows` applies to its
  siblings: a window that reaches past dropped raw regions would recompute them
  as empty and delete materialized history.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @view "platform.timeseries_metrics_disk_hourly"
  @retention_interval "395 days"
  @refresh_start_offset "5 days"
  @refresh_end_offset "10 minutes"
  @refresh_interval "10 minutes"

  def up do
    # serviceradar:allow-startup-maintenance - creates an EMPTY continuous
    # aggregate (WITH NO DATA) and registers its refresh and retention policies,
    # which are catalog rows only. No synchronous refresh or backfill runs on
    # the boot path; the refresh policy materializes the window on its first
    # scheduled run, and every step is a no-op when TimescaleDB is absent.
    execute("""
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{@view}
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('1 hour', timestamp) AS bucket,
      device_id,
      metric_type,
      metric_name,
      series_key,
      tags->>'mount_point' AS mount_point,
      AVG(value)::float8 AS avg_value,
      MIN(value)::float8 AS min_value,
      MAX(value)::float8 AS max_value,
      COUNT(*)::bigint AS sample_count
    FROM platform.timeseries_metrics
    WHERE metric_type = 'sysmon.disk'
      AND device_id IS NOT NULL
      AND tags->>'mount_point' IS NOT NULL
    GROUP BY 1, 2, 3, 4, 5, 6
    WITH NO DATA
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_timeseries_metrics_disk_hourly_bucket_device_mount
    ON #{@view} (bucket DESC, device_id, metric_name, mount_point)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_timeseries_metrics_disk_hourly_device_mount_bucket
    ON #{@view} (device_id, metric_name, mount_point, bucket DESC)
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
          'schedule_interval => INTERVAL ''#{@refresh_interval}'', '
          'if_not_exists => true)',
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
