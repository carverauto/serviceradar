defmodule ServiceRadar.Repo.Migrations.EnsureLogsHypertable do
  @moduledoc """
  Repairs databases where the consolidated baseline left `platform.logs` as a
  regular PostgreSQL table.

  Log continuous aggregates require a TimescaleDB hypertable. Older migrations
  attempted this conversion inside broad best-effort exception handlers, so one
  earlier table failure could leave `logs` unconverted while still recording the
  migration as applied. The consolidated baseline can reproduce the same state.

  Fresh and small databases are repaired automatically. To keep the Helm
  pre-upgrade hook bounded, an unexpectedly large regular table fails with an
  actionable error instead of taking an unbounded startup lock; operators can
  then perform the same conversion in an explicit maintenance window.
  """

  use Ecto.Migration

  @table "platform.logs"
  @time_column "timestamp"
  @max_automatic_migration_bytes 268_435_456
  @lock_timeout "30s"
  @statement_timeout "10min"

  def up do
    chunk_interval_hours = configured_chunk_interval_hours()

    # serviceradar:allow-startup-maintenance - schema-critical conversion is
    # bounded to regular tables no larger than 256 MiB, a 30-second lock
    # acquisition, and ten minutes of execution. The migration remains under
    # Ecto's transaction and migration lock so timeout/failure rolls back
    # atomically and concurrent migrators cannot race it. Larger deployments
    # fail before mutation and require an explicit maintenance-window conversion.
    execute("SET LOCAL lock_timeout = '#{@lock_timeout}'")
    execute("SET LOCAL statement_timeout = '#{@statement_timeout}'")

    execute("""
    DO $$
    DECLARE
      ts_schema text;
      table_bytes bigint;
    BEGIN
      IF to_regclass('#{@table}') IS NULL THEN
        RAISE EXCEPTION 'required log table #{@table} is missing';
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
          AND hypertable_name = 'logs'
      ) THEN
        SELECT pg_total_relation_size('#{@table}'::regclass)
        INTO table_bytes;

        IF table_bytes > #{@max_automatic_migration_bytes} THEN
          RAISE EXCEPTION
            '#{@table} is a regular table of % bytes; automatic hypertable conversion is limited to #{@max_automatic_migration_bytes} bytes',
            table_bytes
            USING HINT = 'run create_hypertable(''platform.logs'', ''timestamp'', migrate_data => true, if_not_exists => true) during a maintenance window, then retry the upgrade';
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
          AND hypertable_name = 'logs'
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
    case Integer.parse(System.get_env("SERVICERADAR_LOGS_CHUNK_INTERVAL_HOURS", "24")) do
      {hours, ""} when hours > 0 ->
        hours

      _ ->
        raise "SERVICERADAR_LOGS_CHUNK_INTERVAL_HOURS must be a positive integer"
    end
  end
end
