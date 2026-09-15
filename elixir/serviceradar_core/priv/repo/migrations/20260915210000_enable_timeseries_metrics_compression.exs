defmodule ServiceRadar.Repo.Migrations.EnableTimeseriesMetricsCompression do
  @moduledoc """
  Enable background compression for the append-only metrics hypertable.

  EventWriter inserts with ON CONFLICT DO NOTHING. Recent chunks remain
  uncompressed; the Timescale policy compresses chunks older than two days.
  Existing compression settings and policies are preserved.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # serviceradar:allow-startup-maintenance - configure compression metadata
    # and its background policy only; never compress existing chunks at startup.
    execute("""
    DO $$
    DECLARE
      ts_schema text;
      compression_enabled boolean;
    BEGIN
      SELECT n.nspname INTO ts_schema
        FROM pg_extension e
        JOIN pg_namespace n ON n.oid = e.extnamespace
       WHERE e.extname = 'timescaledb';
      IF ts_schema IS NULL OR to_regclass('timescaledb_information.hypertables') IS NULL THEN
        RETURN;
      END IF;

      SELECT h.compression_enabled INTO compression_enabled
        FROM timescaledb_information.hypertables h
       WHERE h.hypertable_schema = 'platform' AND h.hypertable_name = 'timeseries_metrics';
      IF NOT FOUND THEN
        RETURN;
      END IF;

      IF NOT compression_enabled THEN
        ALTER TABLE platform.timeseries_metrics SET (
          timescaledb.compress,
          timescaledb.compress_segmentby = 'metric_type, metric_name, device_id',
          timescaledb.compress_orderby = 'timestamp DESC'
        );
      END IF;

      EXECUTE format(
        'SELECT %I.add_compression_policy(%L::regclass, INTERVAL ''2 days'', if_not_exists => true)',
        ts_schema,
        'platform.timeseries_metrics'
      );
    END;
    $$;
    """)
  end

  def down do
    # Existing compressed chunks remain readable. Decompression is an explicit
    # maintenance operation, never an unbounded migration rollback.
    execute("""
    DO $$
    DECLARE
      ts_schema text;
    BEGIN
      SELECT n.nspname INTO ts_schema
        FROM pg_extension e
        JOIN pg_namespace n ON n.oid = e.extnamespace
       WHERE e.extname = 'timescaledb';
      IF ts_schema IS NULL OR to_regclass('timescaledb_information.hypertables') IS NULL THEN
        RETURN;
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.hypertables
         WHERE hypertable_schema = 'platform' AND hypertable_name = 'timeseries_metrics'
      ) THEN
        RETURN;
      END IF;
      EXECUTE format(
        'SELECT %I.remove_compression_policy(%L::regclass, if_exists => true)',
        ts_schema,
        'platform.timeseries_metrics'
      );
    END;
    $$;
    """)
  end
end
