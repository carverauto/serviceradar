defmodule ServiceRadar.Repo.Migrations.ConfigureMtrCompression do
  @moduledoc """
  Configures TimescaleDB compression and retention for `platform.mtr_hops` and
  `platform.mtr_traces`, which had neither.

  serviceradar:allow-startup-maintenance - Timescale policy setup runs as
  privileged database maintenance, like the other hypertable policy migrations in
  this directory.

  ## Why these tables had no policy

  Both were created as hypertables without compression or retention, so MTR data
  accumulated uncompressed indefinitely. Hop rows are the bulk of it: one trace
  produces a row per hop, and the baseline scheduler traces the fleet repeatedly.

  ## Segment-by choice, and why it is NOT `target_ip`

  `compress_segmentby` is `addr` for hops, not the `target_ip` added by
  `20260923120000_add_mtr_hop_target_attribution`. That column is NULL on every
  existing row until the backfill runs, and segmenting by a mostly-NULL column
  produces one enormous NULL segment - the worst case for both compression ratio
  and segment exclusion. `addr` is populated today and is what the hop-address
  analytics filter on.

  Re-segmenting by `target_ip` once the backfill has completed and device-scoped
  queries dominate is a deliberate follow-up, not an oversight: changing
  `compress_segmentby` requires decompressing and recompressing every chunk, which
  is far too expensive to do speculatively here.

  `mtr_traces` segments by `target_ip`, which is a real populated column on that
  table and its primary filter.

  ## Ordering against the backfill

  Compression restricts `UPDATE` on compressed chunks, so enabling it interacts
  with the attribution backfill. This migration does not attempt to sequence them.
  The backfill is written to be decompression-aware instead, because on any
  long-lived installation old chunks will already be compressed by the time anyone
  runs a backfill - making decompression-awareness a requirement of the backfill
  regardless of what this migration does.

  `compression_after` is deliberately longer than the dashboard's default window so
  the data those panels read stays uncompressed and cheap to scan.

  Hand-written, matching the hypertable policy pattern already in this directory.
  Every step is guarded on the TimescaleDB extension and hypertable existing, and
  is idempotent, so it is safe on a database without Timescale and safe to re-run.
  """
  use Ecto.Migration

  @hops_table "mtr_hops"
  @traces_table "mtr_traces"

  # Longer than the built-in dashboard's last_24h default so panel queries read
  # uncompressed chunks.
  @compression_after "7 days"
  @retention_interval "90 days"

  def up do
    set_compression(@hops_table, "addr", ~s("time" DESC, id))
    add_compression_policy(@hops_table, @compression_after)
    add_retention_policy(@hops_table, @retention_interval)

    set_compression(@traces_table, "target_ip", ~s("time" DESC, id))
    add_compression_policy(@traces_table, @compression_after)
    add_retention_policy(@traces_table, @retention_interval)
  end

  def down do
    remove_retention_policy(@traces_table)
    remove_compression_policy(@traces_table)
    unset_compression(@traces_table)

    remove_retention_policy(@hops_table)
    remove_compression_policy(@hops_table)
    unset_compression(@hops_table)
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
