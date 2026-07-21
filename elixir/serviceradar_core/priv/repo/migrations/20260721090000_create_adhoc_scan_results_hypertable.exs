defmodule ServiceRadar.Repo.Migrations.CreateAdhocScanResultsHypertable do
  @moduledoc """
  Creates the adhoc_scan_results hypertable for ad-hoc ICMP/TCP scan results.

  One row per target/port probe of an ad-hoc scan run. Rows are written by the
  event-writer pipeline after results traverse NATS JetStream. MTR results for
  the same run live in mtr_traces and are joined on scan_run_id.

  TimescaleDB hypertable with 30-day retention by default.
  """
  use Ecto.Migration

  @table "adhoc_scan_results"
  @retention_interval "30 days"

  # serviceradar:allow-startup-maintenance - this migration creates the table
  # immediately before converting it into a hypertable, so there are no legacy
  # rows to process. Registering the retention job is bounded metadata setup
  # required before event-writer begins consuming ad-hoc scan results.

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS #{schema()}.#{@table} (
      id           UUID        NOT NULL,
      time         TIMESTAMPTZ NOT NULL,
      scan_run_id  UUID        NOT NULL,
      agent_id     TEXT        NOT NULL,
      gateway_id   TEXT,
      partition    TEXT,
      target_ip    TEXT        NOT NULL,
      mode         TEXT        NOT NULL,
      port         INTEGER,
      available    BOOLEAN     NOT NULL DEFAULT false,
      response_ms  DOUBLE PRECISION,
      service      TEXT,
      PRIMARY KEY (time, id)
    )
    """)

    maybe_create_hypertable(@table, "time")

    execute("""
    CREATE INDEX IF NOT EXISTS idx_adhoc_scan_results_run
      ON #{schema()}.#{@table} (scan_run_id, time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_adhoc_scan_results_time
      ON #{schema()}.#{@table} (time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_adhoc_scan_results_target
      ON #{schema()}.#{@table} (target_ip, time DESC)
    """)

    add_retention_policy(@table, @retention_interval)

    execute("""
    COMMENT ON TABLE #{schema()}.#{@table} IS
      'Ad-hoc ICMP/TCP scan results, one row per target/port probe'
    """)
  end

  def down do
    remove_retention_policy(@table)
    execute("DROP INDEX IF EXISTS #{schema()}.idx_adhoc_scan_results_target")
    execute("DROP INDEX IF EXISTS #{schema()}.idx_adhoc_scan_results_time")
    execute("DROP INDEX IF EXISTS #{schema()}.idx_adhoc_scan_results_run")
    execute("DROP TABLE IF EXISTS #{schema()}.#{@table}")
  end

  defp schema, do: prefix() || "platform"

  defp maybe_create_hypertable(table_name, time_column) do
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

      IF ts_schema IS NOT NULL THEN
        IF NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_name = '#{table_name}'
            AND hypertable_schema = '#{schema()}'
        ) THEN
          EXECUTE format(
            'SELECT %I.create_hypertable(%L::regclass, %L::name, if_not_exists => true)',
            ts_schema,
            '#{schema()}.#{table_name}',
            '#{time_column}'
          );
          RAISE NOTICE 'Created hypertable for #{table_name}';
        END IF;
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not create hypertable for #{table_name}: %', SQLERRM;
    END;
    $$;
    """)
  end

  defp add_retention_policy(table_name, interval) do
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
          'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''#{interval}'', if_not_exists => true)',
          ts_schema,
          table_ident
        );
        RAISE NOTICE 'Added #{interval} retention policy to #{table_name}';
      ELSE
        RAISE NOTICE 'Skipping retention policy for #{table_name} - not a hypertable or TimescaleDB not available';
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not add retention policy to #{table_name}: %', SQLERRM;
    END;
    $$;
    """)
  end

  defp remove_retention_policy(table_name) do
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

      IF ts_schema IS NOT NULL THEN
        EXECUTE format(
          'SELECT %I.remove_retention_policy(%L::regclass, if_exists => true)',
          ts_schema,
          table_ident
        );
        RAISE NOTICE 'Removed retention policy from #{table_name}';
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not remove retention policy from #{table_name}: %', SQLERRM;
    END;
    $$;
    """)
  end
end
