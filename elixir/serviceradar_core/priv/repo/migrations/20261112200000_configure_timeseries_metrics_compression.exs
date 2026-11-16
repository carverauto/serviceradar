defmodule ServiceRadar.Repo.Migrations.ConfigureTimeseriesMetricsCompression do
  @moduledoc """
  Configures TimescaleDB compression and retention for `platform.timeseries_metrics`.

  serviceradar:allow-startup-maintenance - Timescale policy setup runs as
  privileged database maintenance, like the other hypertable policy migrations.

  ## Why this table had no policy

  The table was created as a hypertable without compression or retention, so data
  accumulates uncompressed indefinitely and can fill the database volume.

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
  (default 2 hours) on its next cron run (03:17 by default).

  `retention_days` is 30 — enough to cover dashboards' last_30d windows
  while preventing unbounded growth.

  Rollback is explicitly irreversible and raises `Ecto.MigrationError`. The
  compression and retention policies may predate this migration, and removing
  either would leave the database unprotected until maintenance reconciliation.

  Hand-written, matching the hypertable policy pattern in this directory.
  Every step is guarded on the TimescaleDB extension and hypertable existing,
  and is idempotent, so it is safe on a database without Timescale and safe to re-run.
  """
  use Ecto.Migration

  @table "timeseries_metrics"
  @segmentby "device_id, metric_type, metric_name"
  @orderby ~s("timestamp" DESC, "gateway_id", "series_key")
  @compression_after "6 days"
  @retention_days 30
  @lock_timeout "3s"

  def up do
    set_compression(@table, @segmentby, @orderby)
    add_compression_policy(@table, @compression_after)
    add_retention_policy(@table, @retention_days)
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "cannot roll back timeseries_metrics policy configuration: the compression policy " <>
          "may predate this migration (migration 20261006160000) and DataRetentionWorker may " <>
          "have installed the retention policy; removing either would leave the database without " <>
          "compression or retention protection until maintenance reconciliation"
  end

  defp schema, do: "platform"

  defp set_compression(table_name, segmentby, orderby) do
    execute("""
    DO $$
    DECLARE
      ts_schema text;
      compression_enabled boolean;
    BEGIN
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NULL THEN
        RETURN;
      END IF;

      SELECT h.compression_enabled
      INTO compression_enabled
      FROM timescaledb_information.hypertables h
      WHERE h.hypertable_schema = '#{schema()}'
        AND h.hypertable_name = '#{table_name}';

      IF NOT FOUND OR compression_enabled THEN
        RETURN;
      END IF;

      PERFORM set_config('lock_timeout', '#{@lock_timeout}', true);

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

  defp add_retention_policy(table_name, days) do
    timescale_policy(
      table_name,
      "add_retention_policy(%L::regclass, INTERVAL ''#{days} days'', if_not_exists => true)"
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

      IF ts_schema IS NULL THEN
        RETURN;
      END IF;

      IF EXISTS (
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
    END;
    $$;
    """)
  end
end
