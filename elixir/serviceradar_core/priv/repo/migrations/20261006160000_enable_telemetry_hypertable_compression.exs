defmodule ServiceRadar.Repo.Migrations.EnableTelemetryHypertableCompression do
  @moduledoc """
  Turns Timescale compression on for the two largest raw hypertables,
  `platform.timeseries_metrics` and `platform.ocsf_network_activity`.

  Both already have retention and 24-hour chunks. Neither had a compression
  policy, so every retained chunk stayed uncompressed.

  `compress_after` sits strictly behind the continuous-aggregate refresh
  window that reads the raw table, and strictly inside retention:

    * metrics refresh `start_offset` is 5 days and retention is 7 days, so
      compress after 6 days. A 2-day lag would overlap that refresh and
      Timescale would refuse to compress chunks the aggregate still reads.
    * flow refresh `start_offset` is 31 days and retention is 90 days, so
      compress after 32 days.

  `timeseries_metrics` segments by the equality and rollup columns
  (`device_id`, `metric_type`, `metric_name`). The primary key is
  `(timestamp, gateway_id, series_key)`, and Timescale requires every primary
  key column in `segmentby` or `orderby`, so those three are the order. A
  nullable `device_id` shares one segment; `series_key` stays out of
  `segmentby` because its cardinality would explode the segment count.

  `ocsf_network_activity` segments by `partition` and `protocol_num`. Source
  and destination addresses are too wide to segment on. `flow_uid` is in the
  order so an insert that conflicts on the partial `(flow_uid, time)` index
  does not have to decompress the chunk.

  Hand-written and idempotent. A database without TimescaleDB, or without the
  hypertable, is a no-op. This does not call `compress_chunk` or
  `decompress_chunk`. `down` removes the policy and turns the option off;
  chunks already compressed stay compressed.

  StarRocks does not replace these CNPG tables. Compression stays in place
  for installs that still write them.
  """

  use Ecto.Migration

  @metrics "timeseries_metrics"
  @flows "ocsf_network_activity"
  @metrics_after "6 days"
  @flows_after "32 days"

  def up do
    set_compression(
      @metrics,
      "device_id, metric_type, metric_name",
      ~s("timestamp" DESC, gateway_id, series_key)
    )

    add_compression_policy(@metrics, @metrics_after)

    set_compression(@flows, "partition, protocol_num", ~s("time" DESC, flow_uid))
    add_compression_policy(@flows, @flows_after)
  end

  def down do
    remove_compression_policy(@flows)
    unset_compression(@flows)

    remove_compression_policy(@metrics)
    unset_compression(@metrics)
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
