defmodule ServiceRadar.Repo.Migrations.AddEndpointInventoryHistoryHypertables do
  @moduledoc false
  use Ecto.Migration

  @scan_history_table "endpoint_inventory_scan_history"
  @package_events_table "endpoint_inventory_package_events"
  @retention_interval "395 days"
  @compression_after "7 days"

  def up do
    # serviceradar:allow-startup-maintenance - Timescale policy setup is
    # idempotent and operates only on newly-created empty history tables.
    create_scan_history_table()
    create_package_events_table()
  end

  def down do
    remove_retention_policy(@package_events_table)
    remove_retention_policy(@scan_history_table)
    remove_compression_policy(@package_events_table)
    remove_compression_policy(@scan_history_table)

    execute("DROP INDEX IF EXISTS #{schema()}.endpoint_inventory_package_events_cpes_gin_idx")
    execute("DROP INDEX IF EXISTS #{schema()}.endpoint_inventory_package_events_purl_time_idx")
    execute("DROP INDEX IF EXISTS #{schema()}.endpoint_inventory_package_events_name_time_idx")
    execute("DROP INDEX IF EXISTS #{schema()}.endpoint_inventory_package_events_device_time_idx")
    execute("DROP INDEX IF EXISTS #{schema()}.endpoint_inventory_package_events_agent_time_idx")
    execute("DROP INDEX IF EXISTS #{schema()}.endpoint_inventory_package_events_event_id_uidx")
    execute("DROP TABLE IF EXISTS #{schema()}.#{@package_events_table}")

    execute("DROP INDEX IF EXISTS #{schema()}.endpoint_inventory_scan_history_device_time_idx")
    execute("DROP INDEX IF EXISTS #{schema()}.endpoint_inventory_scan_history_agent_time_idx")
    execute("DROP TABLE IF EXISTS #{schema()}.#{@scan_history_table}")
  end

  defp create_scan_history_table do
    execute("""
    CREATE TABLE IF NOT EXISTS #{schema()}.#{@scan_history_table} (
      id                         UUID        NOT NULL DEFAULT gen_random_uuid(),
      scan_time                  TIMESTAMPTZ NOT NULL,
      scan_ref                   UUID,
      device_uid                 TEXT,
      agent_id                   TEXT        NOT NULL,
      scan_id                    TEXT        NOT NULL,
      collector_name             TEXT,
      collector_version          TEXT,
      state                      TEXT        NOT NULL,
      coverage_state             TEXT        NOT NULL,
      package_count              INTEGER     NOT NULL DEFAULT 0,
      enabled_sources            TEXT[]      NOT NULL DEFAULT ARRAY[]::TEXT[],
      manager_counts             JSONB       NOT NULL DEFAULT '{}'::JSONB,
      source_summaries           JSONB       NOT NULL DEFAULT '[]'::JSONB,
      artifact_count             INTEGER     NOT NULL DEFAULT 0,
      package_set_hash           TEXT,
      previous_package_set_hash  TEXT,
      server_package_set_hash    TEXT,
      artifact_hash              TEXT,
      hash_algorithm             TEXT,
      upload_reason              TEXT,
      package_set_hash_mismatch  BOOLEAN     NOT NULL DEFAULT false,
      package_event_count        INTEGER     NOT NULL DEFAULT 0,
      metadata                   JSONB       NOT NULL DEFAULT '{}'::JSONB,
      inserted_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY (scan_time, id)
    )
    """)

    maybe_create_hypertable(@scan_history_table, "scan_time")

    execute("""
    CREATE INDEX IF NOT EXISTS endpoint_inventory_scan_history_agent_time_idx
      ON #{schema()}.#{@scan_history_table} (agent_id, scan_time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS endpoint_inventory_scan_history_device_time_idx
      ON #{schema()}.#{@scan_history_table} (device_uid, scan_time DESC)
      WHERE device_uid IS NOT NULL
    """)

    set_compression(
      @scan_history_table,
      "agent_id",
      "scan_time DESC"
    )

    add_compression_policy(@scan_history_table, @compression_after)
    add_retention_policy(@scan_history_table, @retention_interval)
  end

  defp create_package_events_table do
    execute("""
    CREATE TABLE IF NOT EXISTS #{schema()}.#{@package_events_table} (
      id                         UUID        NOT NULL DEFAULT gen_random_uuid(),
      event_id                   TEXT        NOT NULL,
      scan_time                  TIMESTAMPTZ NOT NULL,
      scan_ref                   UUID,
      device_uid                 TEXT,
      agent_id                   TEXT        NOT NULL,
      scan_id                    TEXT        NOT NULL,
      event_type                 TEXT        NOT NULL,
      package_manager            TEXT        NOT NULL,
      ecosystem                  TEXT,
      name                       TEXT        NOT NULL,
      architecture               TEXT,
      version                    TEXT,
      previous_version           TEXT,
      new_version                TEXT,
      purl                       TEXT,
      purl_canonical             TEXT,
      previous_purl              TEXT,
      previous_purl_canonical    TEXT,
      cpes                       TEXT[]      NOT NULL DEFAULT ARRAY[]::TEXT[],
      coordinate_hash            TEXT        NOT NULL,
      package_set_hash           TEXT,
      previous_package_set_hash  TEXT,
      artifact_hash              TEXT,
      metadata                   JSONB       NOT NULL DEFAULT '{}'::JSONB,
      inserted_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY (scan_time, id),
      CONSTRAINT endpoint_inventory_package_events_type_chk
        CHECK (event_type IN ('added', 'removed', 'version_changed'))
    )
    """)

    maybe_create_hypertable(@package_events_table, "scan_time")

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS endpoint_inventory_package_events_event_id_uidx
      ON #{schema()}.#{@package_events_table} (scan_time, event_id)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS endpoint_inventory_package_events_agent_time_idx
      ON #{schema()}.#{@package_events_table} (agent_id, scan_time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS endpoint_inventory_package_events_device_time_idx
      ON #{schema()}.#{@package_events_table} (device_uid, scan_time DESC)
      WHERE device_uid IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS endpoint_inventory_package_events_name_time_idx
      ON #{schema()}.#{@package_events_table} (package_manager, name, scan_time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS endpoint_inventory_package_events_purl_time_idx
      ON #{schema()}.#{@package_events_table} (purl_canonical, scan_time DESC)
      WHERE purl_canonical IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS endpoint_inventory_package_events_cpes_gin_idx
      ON #{schema()}.#{@package_events_table} USING GIN (cpes)
    """)

    set_compression(
      @package_events_table,
      "agent_id",
      "scan_time DESC, package_manager, name"
    )

    add_compression_policy(@package_events_table, @compression_after)
    add_retention_policy(@package_events_table, @retention_interval)
  end

  defp schema, do: "platform"

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
            'SELECT %I.create_hypertable(%L::regclass, %L::name, migrate_data => true, if_not_exists => true)',
            ts_schema,
            '#{schema()}.#{table_name}',
            '#{time_column}'
          );
        END IF;
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not create hypertable for #{table_name}: %', SQLERRM;
    END;
    $$;
    """)
  end

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

  defp add_compression_policy(table_name, interval) do
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
          'SELECT %I.add_compression_policy(%L::regclass, INTERVAL ''#{interval}'', if_not_exists => true)',
          ts_schema,
          table_ident
        );
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not add compression policy to #{table_name}: %', SQLERRM;
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
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not add retention policy to #{table_name}: %', SQLERRM;
    END;
    $$;
    """)
  end

  defp remove_compression_policy(table_name) do
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
          'SELECT %I.remove_compression_policy(%L::regclass, if_exists => true)',
          ts_schema,
          table_ident
        );
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not remove compression policy from #{table_name}: %', SQLERRM;
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
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not remove retention policy from #{table_name}: %', SQLERRM;
    END;
    $$;
    """)
  end
end
