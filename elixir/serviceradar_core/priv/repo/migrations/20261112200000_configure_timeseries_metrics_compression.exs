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

  `compress_segmentby` is `gateway_id` — a low-cardinality column that groups
  all metrics from the same gateway into one segment per chunk. Using `series_key`
  would create one segment per unique time series, which is far too many segments
  and degrades both compression ratio and segment exclusion.

  TimescaleDB warns that `series_key` (part of the primary key with `timestamp`
  and `gateway_id`) should appear in segmentby or orderby. The warning is advisory:
  it matters only when rows in a compressed chunk need to be updated in place.
  Timeseries metrics are append-only, so the warning can be disregarded here.

  ## Policy intervals

  `compression_after` is 1 day so the nightly background worker compresses
  yesterday's data before today's writes accumulate on a full disk.

  `retention_interval` is 30 days — enough to cover dashboards' last_30d windows
  while preventing unbounded growth.

  Hand-written, matching the hypertable policy pattern in this directory.
  Every step is guarded on the TimescaleDB extension and hypertable existing,
  and is idempotent, so it is safe on a database without Timescale and safe to re-run.
  """
  use Ecto.Migration

  @table "timeseries_metrics"
  @segmentby "gateway_id"
  @orderby ~s("timestamp" DESC)
  @compression_after "1 day"
  @retention_interval "30 days"

  def up do
    set_compression(@table, @segmentby, @orderby)
    add_compression_policy(@table, @compression_after)
    add_retention_policy(@table, @retention_interval)
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

  defp add_retention_policy(table_name, interval) do
    timescale_policy(
      table_name,
      "add_retention_policy(%L::regclass, INTERVAL ''#{interval}'', if_not_exists => true)"
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
