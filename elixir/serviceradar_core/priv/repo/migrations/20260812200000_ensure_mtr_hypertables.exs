defmodule ServiceRadar.Repo.Migrations.EnsureMtrHypertables do
  @moduledoc """
  Repairs databases where `platform.mtr_traces` and `platform.mtr_hops` were
  left as regular PostgreSQL tables.

  The original creator swallowed Timescale conversion failures, so a fresh
  baseline or a failed create_hypertable left Save Retention as a no-op
  ("policy missing") even though `mtr_settings` persisted successfully.
  """

  use Ecto.Migration

  @tables [{"platform.mtr_traces", "mtr_traces"}, {"platform.mtr_hops", "mtr_hops"}]
  @time_column "time"
  @max_automatic_migration_bytes 268_435_456
  @lock_timeout "30s"
  @statement_timeout "10min"

  def up do
    # serviceradar:allow-startup-maintenance - schema-critical conversion is
    # bounded to regular tables no larger than 256 MiB, a 30-second lock
    # acquisition, and ten minutes of execution.
    execute("SET LOCAL lock_timeout = '#{@lock_timeout}'")
    execute("SET LOCAL statement_timeout = '#{@statement_timeout}'")

    Enum.each(@tables, fn {qualified, name} ->
      convert_table!(qualified, name)
    end)
  end

  def down do
    # Converting a populated hypertable back to a regular table is destructive.
  end

  defp convert_table!(qualified, name) do
    execute("""
    DO $$
    DECLARE
      ts_schema text;
      table_bytes bigint;
    BEGIN
      IF to_regclass('#{qualified}') IS NULL THEN
        RAISE EXCEPTION 'required MTR table #{qualified} is missing';
      END IF;

      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NULL THEN
        RAISE EXCEPTION 'TimescaleDB extension is required for #{qualified}';
      END IF;

      IF NOT EXISTS (
        SELECT 1
        FROM timescaledb_information.hypertables
        WHERE hypertable_schema = 'platform'
          AND hypertable_name = '#{name}'
      ) THEN
        SELECT pg_total_relation_size('#{qualified}'::regclass)
        INTO table_bytes;

        IF table_bytes > #{@max_automatic_migration_bytes} THEN
          RAISE EXCEPTION
            '#{qualified} is a regular table of % bytes; automatic hypertable conversion is limited to #{@max_automatic_migration_bytes} bytes',
            table_bytes
            USING HINT = 'run create_hypertable(''#{qualified}'', ''#{@time_column}'', migrate_data => true, if_not_exists => true) during a maintenance window, then retry the upgrade';
        END IF;

        EXECUTE format(
          'SELECT %I.create_hypertable(%L::regclass, %L::name, create_default_indexes => false, migrate_data => true, if_not_exists => true)',
          ts_schema,
          '#{qualified}',
          '#{@time_column}'
        );
      END IF;

      IF NOT EXISTS (
        SELECT 1
        FROM timescaledb_information.hypertables
        WHERE hypertable_schema = 'platform'
          AND hypertable_name = '#{name}'
      ) THEN
        RAISE EXCEPTION 'failed to convert #{qualified} to a TimescaleDB hypertable';
      END IF;
    END;
    $$;
    """)
  end
end
