defmodule ServiceRadar.Repo.Migrations.EnsureOcsfEventsHypertable do
  @moduledoc """
  Repairs databases where `platform.ocsf_events` was left as a regular table.

  The hourly events CAGG and the dashboard Events Over Time chart both require
  a Timescale hypertable. Older creators swallowed conversion failures, so a
  leftover empty `ocsf_events_hourly_stats` view can exist while raw events
  are never rolled up.
  """

  use Ecto.Migration

  @table "platform.ocsf_events"
  @time_column "time"
  @max_automatic_migration_bytes 268_435_456
  @lock_timeout "30s"
  @statement_timeout "10min"

  def up do
    chunk_interval_hours = configured_chunk_interval_hours()

    # serviceradar:allow-startup-maintenance - schema-critical conversion is
    # bounded to regular tables no larger than 256 MiB, a 30-second lock
    # acquisition, and ten minutes of execution.
    execute("SET LOCAL lock_timeout = '#{@lock_timeout}'")
    execute("SET LOCAL statement_timeout = '#{@statement_timeout}'")

    execute("""
    DO $$
    DECLARE
      ts_schema text;
      table_bytes bigint;
    BEGIN
      IF to_regclass('#{@table}') IS NULL THEN
        RAISE EXCEPTION 'required event table #{@table} is missing';
      END IF;

      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NULL THEN
        RAISE EXCEPTION 'TimescaleDB extension is required for #{@table}';
      END IF;

      IF NOT EXISTS (
        SELECT 1
        FROM timescaledb_information.hypertables
        WHERE hypertable_schema = 'platform'
          AND hypertable_name = 'ocsf_events'
      ) THEN
        SELECT pg_total_relation_size('#{@table}'::regclass)
        INTO table_bytes;

        IF table_bytes > #{@max_automatic_migration_bytes} THEN
          RAISE EXCEPTION
            '#{@table} is a regular table of % bytes; automatic hypertable conversion is limited to #{@max_automatic_migration_bytes} bytes',
            table_bytes
            USING HINT = 'run create_hypertable(''platform.ocsf_events'', ''time'', migrate_data => true, if_not_exists => true) during a maintenance window, then retry the upgrade';
        END IF;

        EXECUTE format(
          'SELECT %I.create_hypertable(%L::regclass, %L::name, chunk_time_interval => INTERVAL ''#{chunk_interval_hours} hours'', create_default_indexes => false, migrate_data => true, if_not_exists => true)',
          ts_schema,
          '#{@table}',
          '#{@time_column}'
        );
      END IF;

      IF NOT EXISTS (
        SELECT 1
        FROM timescaledb_information.hypertables
        WHERE hypertable_schema = 'platform'
          AND hypertable_name = 'ocsf_events'
      ) THEN
        RAISE EXCEPTION 'failed to convert #{@table} to a TimescaleDB hypertable';
      END IF;
    END;
    $$;
    """)
  end

  def down do
    # Converting a populated hypertable back to a regular table is destructive.
  end

  defp configured_chunk_interval_hours do
    case Integer.parse(System.get_env("SERVICERADAR_OCSF_EVENTS_CHUNK_INTERVAL_HOURS", "6")) do
      {hours, ""} when hours > 0 ->
        hours

      _ ->
        raise "SERVICERADAR_OCSF_EVENTS_CHUNK_INTERVAL_HOURS must be a positive integer"
    end
  end
end
