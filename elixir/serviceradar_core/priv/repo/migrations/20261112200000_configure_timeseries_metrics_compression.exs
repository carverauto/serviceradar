defmodule ServiceRadar.Repo.Migrations.ConfigureTimeseriesMetricsCompression do
  @moduledoc """
  Configures TimescaleDB compression and retention for `platform.timeseries_metrics`.

  serviceradar:allow-startup-maintenance - Timescale policy setup runs as
  privileged database maintenance, like the other hypertable policy migrations.

  ## Why this table had no policy

  The table was created as a hypertable without compression or retention, so data
  accumulates uncompressed indefinitely. At production load the table grows at
  ~20 GB/day, filling a 250 Gi PVC in roughly 12 days without compression.

  ## Segment-by choice

  `compress_segmentby` is `device_id, metric_type, metric_name` — groups rows
  by the logical identity of the metric series, giving good segment exclusion
  when queries filter by device or metric type.

  `compress_orderby` appends `gateway_id, series_key` to `timestamp DESC` so
  all primary-key columns are covered, satisfying TimescaleDB's recommendation
  for append-only tables.

  ## Policy intervals

  `compression_after` is 6 days — a conservative initial value. The
  `DataRetentionWorker` reconciles it to the operator-configured lag
  (default 2 hours) on startup, so the effective window is short-lived.

  `retention_days` is 30 — enough to cover dashboards' last_30d windows
  while preventing unbounded growth. Routed through `RetentionFence` so the
  cold-tier offload path removes the policy rather than letting the background
  worker drop un-exported chunks.

  Hand-written, matching the hypertable policy pattern in this directory.
  Every step is guarded on the TimescaleDB extension and hypertable existing,
  and is idempotent, so it is safe on a database without Timescale and safe to re-run.
  """
  use Ecto.Migration

  alias ServiceRadar.ColdTier.RetentionFence

  @table "timeseries_metrics"
  @segmentby "device_id, metric_type, metric_name"
  @orderby ~s("timestamp" DESC, "gateway_id", "series_key")
  @compression_after "6 days"
  @retention_days 30

  def up do
    set_compression(@table, @segmentby, @orderby)
    add_compression_policy(@table, @compression_after)
    RetentionFence.reconcile_policy(@table, @retention_days, repo: repo())
  end

  def down do
    remove_retention_policy(@table)
    remove_compression_policy(@table)
    unset_compression(@table)
  end

  defp schema, do: "platform"

  defp set_compression(table_name, segmentby, orderby) do
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

      IF ts_schema IS NOT NULL
         AND EXISTS (
           SELECT 1
           FROM timescaledb_information.hypertables
           WHERE hypertable_schema = '#{schema()}'
             AND hypertable_name = '#{table_name}'
         ) THEN
        EXECUTE format(
          'ALTER TABLE %I.%I SET (
             timescaledb.compress,
             timescaledb.compress_segmentby = %L,
             timescaledb.compress_orderby = %L
           )',
          '#{schema()}',
          '#{table_name}',
          '#{segmentby}',
          '#{orderby}'
        );
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not configure compression for #{table_name}: %', SQLERRM;
    END;
    $$;
    """)
  end

  defp unset_compression(table_name) do
    execute("""
    DO $$
    BEGIN
      EXECUTE format(
        'ALTER TABLE %I.%I SET (timescaledb.compress = false)',
        '#{schema()}',
        '#{table_name}'
      );
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not disable compression for #{table_name}: %', SQLERRM;
    END;
    $$;
    """)
  end

  defp add_compression_policy(table_name, interval) do
    timescale_policy(
      table_name,
      "add_compression_policy(%L::regclass, INTERVAL ''#{interval}'', if_not_exists => true)"
    )
  end

  defp remove_compression_policy(table_name) do
    timescale_policy(
      table_name,
      "remove_compression_policy(%L::regclass, if_not_exists => true)"
    )
  end

  defp remove_retention_policy(table_name) do
    timescale_policy(
      table_name,
      "remove_retention_policy(%L::regclass, if_not_exists => true)"
    )
  end

  defp timescale_policy(table_name, call_fragment) do
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
          'SELECT %I.#{call_fragment}',
          ts_schema,
          table_ident
        );
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not apply policy for #{table_name}: %', SQLERRM;
    END;
    $$;
    """)
  end
end
