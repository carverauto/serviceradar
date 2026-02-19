defmodule ServiceRadar.Repo.Migrations.CreateBmpRoutingEvents do
  @moduledoc """
  Stores high-volume BMP routing events in a dedicated hypertable with short retention.

  This keeps causal overlays fast while preventing long-lived routing payload growth
  inside general-purpose event tables.
  """
  use Ecto.Migration

  @table "bmp_routing_events"
  @retention_interval "3 days"

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS #{prefix()}.#{@table} (
      id          UUID        NOT NULL,
      time        TIMESTAMPTZ NOT NULL,
      event_type  TEXT        NOT NULL,
      severity_id INTEGER,
      router_id   TEXT,
      router_ip   TEXT,
      peer_ip     TEXT,
      peer_asn    BIGINT,
      local_asn   BIGINT,
      prefix      TEXT,
      message     TEXT,
      metadata    JSONB       NOT NULL DEFAULT '{}'::jsonb,
      raw_data    TEXT,
      created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY (time, id)
    )
    """)

    maybe_create_hypertable(@table, "time")

    execute("""
    CREATE INDEX IF NOT EXISTS idx_bmp_routing_events_time
      ON #{prefix()}.#{@table} (time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_bmp_routing_events_router_peer
      ON #{prefix()}.#{@table} (router_id, peer_ip, time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_bmp_routing_events_event_type
      ON #{prefix()}.#{@table} (event_type, time DESC)
    """)

    execute("""
    COMMENT ON TABLE #{prefix()}.#{@table} IS
      'High-volume BMP routing events with short retention for overlay replay'
    """)

    add_retention_policy(@table, @retention_interval)
  end

  def down do
    remove_retention_policy(@table)
    execute("DROP INDEX IF EXISTS #{prefix()}.idx_bmp_routing_events_event_type")
    execute("DROP INDEX IF EXISTS #{prefix()}.idx_bmp_routing_events_router_peer")
    execute("DROP INDEX IF EXISTS #{prefix()}.idx_bmp_routing_events_time")
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
