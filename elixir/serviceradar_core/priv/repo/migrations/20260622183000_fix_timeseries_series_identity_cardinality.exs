defmodule ServiceRadar.Repo.Migrations.FixTimeseriesSeriesIdentityCardinality do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @raw_metric_tables [
    "timeseries_metrics",
    "cpu_metrics",
    "cpu_cluster_metrics",
    "disk_metrics",
    "memory_metrics",
    "process_metrics"
  ]

  @volatile_tag_keys [
    "available",
    "available_bytes",
    "buffered_bytes",
    "cached_bytes",
    "execution_id",
    "free_bytes",
    "metric",
    "packet_loss",
    "payload_kind",
    "producer_id",
    "producer_kind",
    "source",
    "status",
    "sweep_group_id",
    "swap_total_bytes",
    "swap_used_bytes",
    "total_bytes",
    "used_bytes",
    "value"
  ]

  def up do
    # serviceradar:allow-startup-maintenance - this only replaces the stable-tags
    # helper and registers Timescale retention/chunk policies for a fixed set of
    # hypertables; it does not backfill metric rows on first boot.
    replace_stable_tags_function(@volatile_tag_keys)

    Enum.each(@raw_metric_tables, fn table_name ->
      replace_retention_policy(table_name, 7)
      shrink_chunk_interval(table_name, 24)
    end)
  end

  def down do
    replace_stable_tags_function(["available", "metric", "packet_loss"])
  end

  defp replace_stable_tags_function(volatile_tag_keys) do
    execute("""
    CREATE OR REPLACE FUNCTION platform.timeseries_series_stable_tags(p_tags jsonb)
    RETURNS text
    LANGUAGE sql
    IMMUTABLE
    PARALLEL SAFE
    AS $$
      SELECT string_agg(
        platform.timeseries_series_component('tag:' || entry.key, entry.value),
        '|' ORDER BY entry.key
      )
      FROM jsonb_each_text(COALESCE(p_tags, '{}'::jsonb)) AS entry(key, value)
      WHERE COALESCE(btrim(entry.value), '') <> ''
        AND entry.key NOT IN (#{quoted_values(volatile_tag_keys)})
    $$;
    """)
  end

  defp replace_retention_policy(table_name, retention_days) do
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
          'SELECT %I.remove_retention_policy(%L::regclass, if_exists => true)',
          ts_schema,
          table_ident
        );

        EXECUTE format(
          'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''#{retention_days} days'', if_not_exists => true)',
          ts_schema,
          table_ident
        );

        RAISE NOTICE 'Set #{retention_days} day retention policy on #{table_name}';
      ELSE
        RAISE NOTICE 'Skipping retention policy for #{table_name} - not a hypertable or TimescaleDB not available';
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not update retention policy for #{table_name}: %', SQLERRM;
    END;
    $$;
    """)
  end

  defp shrink_chunk_interval(table_name, chunk_hours) do
    execute("""
    DO $$
    DECLARE
      table_ident text;
      ts_schema text;
      current_interval interval;
    BEGIN
      table_ident := format('%I.%I', '#{schema()}', '#{table_name}');

      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NULL
         OR NOT EXISTS (
           SELECT 1
           FROM timescaledb_information.hypertables
           WHERE hypertable_schema = '#{schema()}'
             AND hypertable_name = '#{table_name}'
         ) THEN
        RAISE NOTICE 'Skipping chunk interval for #{table_name} - not a hypertable or TimescaleDB not available';
        RETURN;
      END IF;

      SELECT time_interval
      INTO current_interval
      FROM timescaledb_information.dimensions
      WHERE hypertable_schema = '#{schema()}'
        AND hypertable_name = '#{table_name}'
        AND time_interval IS NOT NULL
      LIMIT 1;

      IF current_interval IS NULL OR current_interval > INTERVAL '#{chunk_hours} hours' THEN
        EXECUTE format(
          'SELECT %I.set_chunk_time_interval(%L::regclass, INTERVAL ''#{chunk_hours} hours'')',
          ts_schema,
          table_ident
        );

        RAISE NOTICE 'Shrunk chunk interval on #{table_name} to #{chunk_hours} hours';
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not update chunk interval for #{table_name}: %', SQLERRM;
    END;
    $$;
    """)
  end

  defp quoted_values(values) do
    Enum.map_join(values, ", ", &("'" <> String.replace(&1, "'", "''") <> "'"))
  end

  defp schema, do: prefix() || "platform"
end
