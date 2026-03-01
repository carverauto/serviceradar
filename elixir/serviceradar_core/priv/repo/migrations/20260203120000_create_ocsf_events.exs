defmodule ServiceRadar.Repo.Migrations.CreateOcsfEvents do
  @moduledoc """
  Creates the OCSF Event Log Activity hypertable used by log promotion.

  This migration is idempotent and safe to re-run.
  """
  use Ecto.Migration

  @table "ocsf_events"
  @retention_interval "14 days"

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS #{prefix() || "platform"}.#{@table} (
      id           UUID        NOT NULL,
      time         TIMESTAMPTZ NOT NULL,
      class_uid    INTEGER     NOT NULL,
      category_uid INTEGER     NOT NULL,
      type_uid     INTEGER     NOT NULL,
      activity_id  INTEGER     NOT NULL,
      activity_name TEXT,
      severity_id  INTEGER,
      severity     TEXT,
      message      TEXT,
      status_id    INTEGER,
      status       TEXT,
      status_code  TEXT,
      status_detail TEXT,
      metadata     JSONB       NOT NULL DEFAULT '{}'::jsonb,
      observables  JSONB       NOT NULL DEFAULT '[]'::jsonb,
      trace_id     TEXT,
      span_id      TEXT,
      actor        JSONB       NOT NULL DEFAULT '{}'::jsonb,
      device       JSONB       NOT NULL DEFAULT '{}'::jsonb,
      src_endpoint JSONB       NOT NULL DEFAULT '{}'::jsonb,
      dst_endpoint JSONB       NOT NULL DEFAULT '{}'::jsonb,
      log_name     TEXT,
      log_provider TEXT,
      log_level    TEXT,
      log_version  TEXT,
      unmapped     JSONB       NOT NULL DEFAULT '{}'::jsonb,
      raw_data     TEXT,
      created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY (time, id)
    )
    """)

    maybe_create_hypertable(@table, "time")

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_events_time
      ON #{prefix() || "platform"}.#{@table} (time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_events_severity
      ON #{prefix() || "platform"}.#{@table} (severity_id)
    """)

    execute("""
    COMMENT ON TABLE #{prefix() || "platform"}.#{@table} IS
      'OCSF Event Log Activity entries from log promotion and internal writers'
    """)

    add_retention_policy(@table, @retention_interval)
  end

  def down do
    remove_retention_policy(@table)
    execute("DROP INDEX IF EXISTS #{prefix() || "platform"}.idx_ocsf_events_severity")
    execute("DROP INDEX IF EXISTS #{prefix() || "platform"}.idx_ocsf_events_time")
    execute("DROP TABLE IF EXISTS #{prefix() || "platform"}.#{@table}")
  end

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
            AND hypertable_schema = '#{prefix() || "platform"}'
        ) THEN
          EXECUTE format(
            'SELECT %I.create_hypertable(%L::regclass, %L::name, migrate_data => true, if_not_exists => true)',
            ts_schema,
            '#{prefix() || "platform"}.#{table_name}',
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
      table_ident := format('%I.%I', '#{prefix() || "platform"}', '#{table_name}');
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NOT NULL
         AND EXISTS (
           SELECT 1
           FROM timescaledb_information.hypertables
           WHERE hypertable_schema = '#{prefix() || "platform"}'
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
      table_ident := format('%I.%I', '#{prefix() || "platform"}', '#{table_name}');
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
