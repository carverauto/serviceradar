defmodule ServiceRadar.Repo.Migrations.CreateMdnsDiscoveryEvents do
  @moduledoc """
  Creates the mdns_discovery_events hypertable for mDNS discovery observability.

  This migration is idempotent and safe to re-run.
  """
  use Ecto.Migration

  @table "mdns_discovery_events"
  @retention_interval "14 days"

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS #{prefix()}.#{@table} (
      id           UUID        NOT NULL,
      time         TIMESTAMPTZ NOT NULL,
      record_type  TEXT,
      source_ip    TEXT,
      hostname     TEXT,
      resolved_addr TEXT,
      dns_name     TEXT,
      dns_ttl      INTEGER,
      device_uid   TEXT,
      created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY (time, id)
    )
    """)

    maybe_create_hypertable(@table, "time")

    execute("""
    CREATE INDEX IF NOT EXISTS idx_mdns_discovery_hostname_time
      ON #{prefix()}.#{@table} (hostname, time DESC)
    """)

    execute("""
    COMMENT ON TABLE #{prefix()}.#{@table} IS
      'mDNS discovery events from multicast DNS collector'
    """)

    add_retention_policy(@table, @retention_interval)
  end

  def down do
    remove_retention_policy(@table)
    execute("DROP INDEX IF EXISTS #{prefix()}.idx_mdns_discovery_hostname_time")
    execute("DROP TABLE IF EXISTS #{prefix()}.#{@table}")
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
            AND hypertable_schema = '#{prefix()}'
        ) THEN
          EXECUTE format(
            'SELECT %I.create_hypertable(%L::regclass, %L::name, migrate_data => true, if_not_exists => true)',
            ts_schema,
            '#{prefix()}.#{table_name}',
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
      table_ident := format('%I.%I', '#{prefix()}', '#{table_name}');
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NOT NULL
         AND EXISTS (
           SELECT 1
           FROM timescaledb_information.hypertables
           WHERE hypertable_schema = '#{prefix()}'
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
      table_ident := format('%I.%I', '#{prefix()}', '#{table_name}');
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
