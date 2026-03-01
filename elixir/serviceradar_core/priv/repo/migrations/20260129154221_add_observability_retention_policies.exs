defmodule ServiceRadar.Repo.Migrations.AddObservabilityRetentionPolicies do
  @moduledoc """
  Adds TimescaleDB retention policies to observability hypertables.

  Retention intervals are tiered by data type:
  - 7 days: High-volume telemetry (cpu, disk, memory, process, timeseries metrics)
  - 14 days: Monitoring data (service_status, events)
  - 30 days: APM data (otel_traces, otel_metrics, logs, device_updates)
  - 90 days: Aggregated data (otel_metrics_hourly_stats)

  This migration is idempotent - safe to run multiple times.
  """
  use Ecto.Migration

  # Tables grouped by retention tier
  @retention_7_days [
    "cpu_metrics",
    "disk_metrics",
    "memory_metrics",
    "process_metrics",
    "timeseries_metrics"
  ]

  @retention_14_days [
    "service_status",
    "events"
  ]

  @retention_30_days [
    "otel_traces",
    "otel_metrics",
    "logs",
    "device_updates"
  ]

  @retention_90_days [
    "otel_metrics_hourly_stats"
  ]

  @all_tables @retention_7_days ++ @retention_14_days ++ @retention_30_days ++ @retention_90_days

  def up do
    # Add retention policies for each tier
    Enum.each(@retention_7_days, &add_retention_policy(&1, "7 days"))
    Enum.each(@retention_14_days, &add_retention_policy(&1, "14 days"))
    Enum.each(@retention_30_days, &add_retention_policy(&1, "30 days"))
    Enum.each(@retention_90_days, &add_retention_policy(&1, "90 days"))
  end

  def down do
    Enum.each(@all_tables, &remove_retention_policy/1)
  end

  defp add_retention_policy(table_name, interval) do
    execute("""
    DO $$
    DECLARE
      table_ident text;
      ts_schema text;
    BEGIN
      table_ident := format('%I.%I', '#{prefix() || "platform"}', '#{table_name}');
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      -- Only add retention policy if TimescaleDB is available and table is a hypertable
      IF ts_schema IS NOT NULL
         AND EXISTS (
           SELECT 1
           FROM timescaledb_information.hypertables
           WHERE hypertable_schema = '#{prefix() || "platform"}'
             AND hypertable_name = '#{table_name}'
         ) THEN
        EXECUTE format(
          'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''#{interval}'', if_not_exists => true)',
          ts_schema,
          table_ident
        );
        RAISE NOTICE 'Added #{interval} retention policy to #{table_name}';
      ELSE
        RAISE NOTICE 'Skipping retention policy for #{table_name} - not a hypertable or TimescaleDB not available';
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
      table_ident := format('%I.%I', '#{prefix() || "platform"}', '#{table_name}');
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
        RAISE NOTICE 'Removed retention policy from #{table_name}';
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not remove retention policy from #{table_name}: %', SQLERRM;
    END;
    $$;
    """)
  end
end
