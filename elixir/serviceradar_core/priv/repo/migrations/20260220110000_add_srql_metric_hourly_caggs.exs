defmodule ServiceRadar.Repo.Migrations.AddSrqlMetricHourlyCaggs do
  @moduledoc """
  Creates hourly TimescaleDB continuous aggregates for SRQL metric entities.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @cpu_view "platform.cpu_metrics_hourly"
  @memory_view "platform.memory_metrics_hourly"
  @disk_view "platform.disk_metrics_hourly"
  @process_view "platform.process_metrics_hourly"
  @timeseries_view "platform.timeseries_metrics_hourly"

  @retention_interval "395 days"
  @refresh_start_offset "32 days"
  @refresh_end_offset "10 minutes"
  @refresh_interval "10 minutes"

  def up do
    execute("""
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{@cpu_view}
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('1 hour', timestamp) AS bucket,
      device_id,
      host_id,
      AVG(usage_percent)::float8 AS avg_usage_percent,
      MAX(usage_percent)::float8 AS max_usage_percent,
      COUNT(*)::bigint AS sample_count
    FROM platform.cpu_metrics
    GROUP BY 1, 2, 3
    WITH NO DATA
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_cpu_metrics_hourly_bucket_device_host
    ON #{@cpu_view} (bucket DESC, device_id, host_id)
    """)

    execute("""
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{@memory_view}
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('1 hour', timestamp) AS bucket,
      device_id,
      host_id,
      AVG(usage_percent)::float8 AS avg_usage_percent,
      MAX(usage_percent)::float8 AS max_usage_percent,
      AVG(used_bytes)::float8 AS avg_used_bytes,
      AVG(available_bytes)::float8 AS avg_available_bytes,
      COUNT(*)::bigint AS sample_count
    FROM platform.memory_metrics
    GROUP BY 1, 2, 3
    WITH NO DATA
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_memory_metrics_hourly_bucket_device_host
    ON #{@memory_view} (bucket DESC, device_id, host_id)
    """)

    execute("""
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{@disk_view}
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('1 hour', timestamp) AS bucket,
      device_id,
      host_id,
      mount_point,
      AVG(usage_percent)::float8 AS avg_usage_percent,
      MAX(usage_percent)::float8 AS max_usage_percent,
      AVG(used_bytes)::float8 AS avg_used_bytes,
      AVG(available_bytes)::float8 AS avg_available_bytes,
      COUNT(*)::bigint AS sample_count
    FROM platform.disk_metrics
    GROUP BY 1, 2, 3, 4
    WITH NO DATA
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_disk_metrics_hourly_bucket_device_host_mount
    ON #{@disk_view} (bucket DESC, device_id, host_id, mount_point)
    """)

    execute("""
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{@process_view}
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('1 hour', timestamp) AS bucket,
      device_id,
      host_id,
      name,
      AVG(cpu_usage)::float8 AS avg_cpu_usage,
      MAX(cpu_usage)::float8 AS max_cpu_usage,
      AVG(memory_usage)::float8 AS avg_memory_usage,
      MAX(memory_usage)::float8 AS max_memory_usage,
      COUNT(*)::bigint AS sample_count
    FROM platform.process_metrics
    GROUP BY 1, 2, 3, 4
    WITH NO DATA
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_process_metrics_hourly_bucket_device_host_name
    ON #{@process_view} (bucket DESC, device_id, host_id, name)
    """)

    execute("""
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{@timeseries_view}
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('1 hour', timestamp) AS bucket,
      device_id,
      metric_type,
      metric_name,
      AVG(value)::float8 AS avg_value,
      MIN(value)::float8 AS min_value,
      MAX(value)::float8 AS max_value,
      COUNT(*)::bigint AS sample_count
    FROM platform.timeseries_metrics
    GROUP BY 1, 2, 3, 4
    WITH NO DATA
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_timeseries_metrics_hourly_bucket_device_type_name
    ON #{@timeseries_view} (bucket DESC, device_id, metric_type, metric_name)
    """)

    execute("""
    DO $$
    DECLARE
      ts_schema text;
      view_ident text;
    BEGIN
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NULL THEN
        RETURN;
      END IF;

      FOREACH view_ident IN ARRAY ARRAY[
        '#{@cpu_view}',
        '#{@memory_view}',
        '#{@disk_view}',
        '#{@process_view}',
        '#{@timeseries_view}'
      ] LOOP
        BEGIN
          EXECUTE format(
            'SELECT %I.add_continuous_aggregate_policy(%L::regclass, '
            'start_offset => INTERVAL ''#{@refresh_start_offset}'', '
            'end_offset => INTERVAL ''#{@refresh_end_offset}'', '
            'schedule_interval => INTERVAL ''#{@refresh_interval}'')',
            ts_schema,
            view_ident
          );
        EXCEPTION
          WHEN others THEN
            NULL;
        END;

        BEGIN
          EXECUTE format(
            'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''#{@retention_interval}'', if_not_exists => true)',
            ts_schema,
            view_ident
          );
        EXCEPTION
          WHEN others THEN
            NULL;
        END;

        BEGIN
          EXECUTE format(
            'CALL %I.refresh_continuous_aggregate(%L::regclass, NOW() - INTERVAL ''#{@retention_interval}'', NOW())',
            ts_schema,
            view_ident
          );
        EXCEPTION
          WHEN others THEN
            NULL;
        END;
      END LOOP;
    END;
    $$;
    """)
  end

  def down do
    execute("""
    DO $$
    DECLARE
      ts_schema text;
      view_ident text;
    BEGIN
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NULL THEN
        RETURN;
      END IF;

      FOREACH view_ident IN ARRAY ARRAY[
        '#{@cpu_view}',
        '#{@memory_view}',
        '#{@disk_view}',
        '#{@process_view}',
        '#{@timeseries_view}'
      ] LOOP
        BEGIN
          EXECUTE format(
            'SELECT %I.remove_retention_policy(%L::regclass, if_exists => true)',
            ts_schema,
            view_ident
          );
        EXCEPTION
          WHEN others THEN
            NULL;
        END;

        BEGIN
          EXECUTE format(
            'SELECT %I.remove_continuous_aggregate_policy(%L::regclass)',
            ts_schema,
            view_ident
          );
        EXCEPTION
          WHEN others THEN
            NULL;
        END;
      END LOOP;
    END;
    $$;
    """)

    execute("DROP MATERIALIZED VIEW IF EXISTS #{@timeseries_view}")
    execute("DROP MATERIALIZED VIEW IF EXISTS #{@process_view}")
    execute("DROP MATERIALIZED VIEW IF EXISTS #{@disk_view}")
    execute("DROP MATERIALIZED VIEW IF EXISTS #{@memory_view}")
    execute("DROP MATERIALIZED VIEW IF EXISTS #{@cpu_view}")
  end
end
