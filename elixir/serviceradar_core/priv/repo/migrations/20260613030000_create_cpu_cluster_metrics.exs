defmodule ServiceRadar.Repo.Migrations.CreateCpuClusterMetrics do
  @moduledoc """
  Creates the CPU cluster metrics hypertable used by Sysmon metrics ingestion.

  The Ash resource is marked `migrate? false`, so this table must exist before
  cluster-bearing CPU samples reach the metrics DB-sync consumer.
  """
  use Ecto.Migration

  # serviceradar:allow-startup-maintenance - add_retention_policy only registers a background
  # retention job on the freshly-created (empty) cpu_cluster_metrics hypertable; no synchronous
  # data maintenance runs on the first-boot path.

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS #{schema()}.cpu_cluster_metrics (
      timestamp    TIMESTAMPTZ NOT NULL,
      gateway_id   TEXT        NOT NULL,
      agent_id     TEXT,
      host_id      TEXT,
      cluster      TEXT        NOT NULL,
      frequency_hz FLOAT8,
      device_id    TEXT,
      partition    TEXT,
      created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY (timestamp, gateway_id, cluster)
    )
    """)

    maybe_create_hypertable("cpu_cluster_metrics", "timestamp")

    execute("""
    CREATE INDEX IF NOT EXISTS idx_cpu_cluster_metrics_timestamp
    ON #{schema()}.cpu_cluster_metrics (timestamp DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_cpu_cluster_metrics_device
    ON #{schema()}.cpu_cluster_metrics (device_id, cluster, timestamp DESC)
    WHERE device_id IS NOT NULL
    """)

    add_retention_policy("cpu_cluster_metrics", "7 days")
  end

  def down do
    remove_retention_policy("cpu_cluster_metrics")
    execute("DROP INDEX IF EXISTS #{schema()}.idx_cpu_cluster_metrics_device")
    execute("DROP INDEX IF EXISTS #{schema()}.idx_cpu_cluster_metrics_timestamp")
    execute("DROP TABLE IF EXISTS #{schema()}.cpu_cluster_metrics")
  end

  defp schema, do: prefix() || "platform"

  defp maybe_create_hypertable(table_name, time_column) do
    execute("""
    DO $$
    DECLARE
      table_ident text;
      ts_schema text;
    BEGIN
      table_ident := format('%I.%I', '#{schema()}', '#{table_name}');

      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NOT NULL
         AND NOT EXISTS (
           SELECT 1
           FROM timescaledb_information.hypertables
           WHERE hypertable_schema = '#{schema()}'
             AND hypertable_name = '#{table_name}'
         ) THEN
        EXECUTE format(
          'SELECT %I.create_hypertable(%L::regclass, %L::name, migrate_data => true, if_not_exists => true)',
          ts_schema,
          table_ident,
          '#{time_column}'
        );
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not create hypertable for #{table_name}: %', SQLERRM;
    END;
    $$;
    """)
  end

  defp add_retention_policy(table_name, interval) do
    execute("""
    DO $$
    DECLARE
      table_ident text;
      ts_schema text;
    BEGIN
      table_ident := format('%I.%I', '#{schema()}', '#{table_name}');

      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NOT NULL
         AND EXISTS (
           SELECT 1
           FROM timescaledb_information.hypertables
           WHERE hypertable_schema = '#{schema()}'
             AND hypertable_name = '#{table_name}'
         ) THEN
        EXECUTE format(
          'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''#{interval}'', if_not_exists => true)',
          ts_schema,
          table_ident
        );
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not add retention policy to #{table_name}: %', SQLERRM;
    END;
    $$;
    """)
  end

  defp remove_retention_policy(table_name) do
    execute("""
    DO $$
    DECLARE
      table_ident text;
      ts_schema text;
    BEGIN
      table_ident := format('%I.%I', '#{schema()}', '#{table_name}');

      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NOT NULL THEN
        EXECUTE format(
          'SELECT %I.remove_retention_policy(%L::regclass, if_exists => true)',
          ts_schema,
          table_ident
        );
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not remove retention policy from #{table_name}: %', SQLERRM;
    END;
    $$;
    """)
  end
end
