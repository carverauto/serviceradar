defmodule ServiceRadar.Repo.Migrations.AddEndpointInventoryCountRollups do
  @moduledoc false
  use Ecto.Migration

  @package_count_history_table "endpoint_inventory_package_count_history"
  @cpe_count_history_table "endpoint_inventory_cpe_count_history"
  @package_counts_hourly "endpoint_inventory_package_counts_hourly"
  @cpe_counts_hourly "endpoint_inventory_cpe_counts_hourly"
  @retention_interval "395 days"
  @compression_after "7 days"

  def up do
    # serviceradar:allow-startup-maintenance - Timescale policy/CAGG setup uses
    # WITH NO DATA and only wires empty count-history tables on bootstrap.
    create_current_count_tables()
    create_count_history_tables()
    create_continuous_aggregates()
  end

  def down do
    drop_continuous_aggregate_policy(@cpe_counts_hourly)
    drop_continuous_aggregate_policy(@package_counts_hourly)

    execute("DROP MATERIALIZED VIEW IF EXISTS #{schema()}.#{@cpe_counts_hourly}")
    execute("DROP MATERIALIZED VIEW IF EXISTS #{schema()}.#{@package_counts_hourly}")

    remove_retention_policy(@cpe_count_history_table)
    remove_retention_policy(@package_count_history_table)
    remove_compression_policy(@cpe_count_history_table)
    remove_compression_policy(@package_count_history_table)

    execute("DROP TABLE IF EXISTS #{schema()}.#{@cpe_count_history_table}")
    execute("DROP TABLE IF EXISTS #{schema()}.#{@package_count_history_table}")
    execute("DROP TABLE IF EXISTS #{schema()}.endpoint_inventory_current_cpe_counts")
    execute("DROP TABLE IF EXISTS #{schema()}.endpoint_inventory_current_package_counts")
  end

  defp create_current_count_tables do
    execute("""
    CREATE TABLE IF NOT EXISTS #{schema()}.endpoint_inventory_current_package_counts (
      coordinate_hash  TEXT        PRIMARY KEY,
      package_manager  TEXT        NOT NULL,
      ecosystem        TEXT,
      name             TEXT        NOT NULL,
      version          TEXT,
      architecture     TEXT,
      purl_canonical   TEXT,
      cpes             TEXT[]      NOT NULL DEFAULT ARRAY[]::TEXT[],
      host_count       INTEGER     NOT NULL DEFAULT 0 CHECK (host_count >= 0),
      first_seen_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
      last_seen_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS endpoint_inventory_current_package_counts_name_idx
      ON #{schema()}.endpoint_inventory_current_package_counts (package_manager, name, version)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS endpoint_inventory_current_package_counts_purl_idx
      ON #{schema()}.endpoint_inventory_current_package_counts (purl_canonical)
      WHERE purl_canonical IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS endpoint_inventory_current_package_counts_cpes_gin_idx
      ON #{schema()}.endpoint_inventory_current_package_counts USING GIN (cpes)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{schema()}.endpoint_inventory_current_cpe_counts (
      cpe          TEXT        PRIMARY KEY,
      host_count   INTEGER     NOT NULL DEFAULT 0 CHECK (host_count >= 0),
      first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      last_seen_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS endpoint_inventory_current_cpe_counts_host_count_idx
      ON #{schema()}.endpoint_inventory_current_cpe_counts (host_count DESC)
    """)
  end

  defp create_count_history_tables do
    execute("""
    CREATE TABLE IF NOT EXISTS #{schema()}.#{@package_count_history_table} (
      id               UUID        NOT NULL DEFAULT gen_random_uuid(),
      scan_time        TIMESTAMPTZ NOT NULL,
      event_id         TEXT        NOT NULL,
      coordinate_hash  TEXT        NOT NULL,
      package_manager  TEXT        NOT NULL,
      ecosystem        TEXT,
      name             TEXT        NOT NULL,
      version          TEXT,
      architecture     TEXT,
      purl_canonical   TEXT,
      cpes             TEXT[]      NOT NULL DEFAULT ARRAY[]::TEXT[],
      host_count       INTEGER     NOT NULL DEFAULT 0 CHECK (host_count >= 0),
      count_delta      INTEGER     NOT NULL,
      agent_id         TEXT        NOT NULL,
      device_uid       TEXT,
      scan_id          TEXT        NOT NULL,
      inserted_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY (scan_time, id)
    )
    """)

    maybe_create_hypertable(@package_count_history_table, "scan_time")

    execute("""
    CREATE INDEX IF NOT EXISTS endpoint_inventory_package_count_history_coord_time_idx
      ON #{schema()}.#{@package_count_history_table} (coordinate_hash, scan_time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS endpoint_inventory_package_count_history_name_time_idx
      ON #{schema()}.#{@package_count_history_table} (package_manager, name, version, scan_time DESC)
    """)

    set_compression(@package_count_history_table, "coordinate_hash", "scan_time DESC")
    add_compression_policy(@package_count_history_table, @compression_after)
    add_retention_policy(@package_count_history_table, @retention_interval)

    execute("""
    CREATE TABLE IF NOT EXISTS #{schema()}.#{@cpe_count_history_table} (
      id          UUID        NOT NULL DEFAULT gen_random_uuid(),
      scan_time   TIMESTAMPTZ NOT NULL,
      event_id    TEXT        NOT NULL,
      cpe         TEXT        NOT NULL,
      host_count  INTEGER     NOT NULL DEFAULT 0 CHECK (host_count >= 0),
      count_delta INTEGER     NOT NULL,
      agent_id    TEXT        NOT NULL,
      device_uid  TEXT,
      scan_id     TEXT        NOT NULL,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY (scan_time, id)
    )
    """)

    maybe_create_hypertable(@cpe_count_history_table, "scan_time")

    execute("""
    CREATE INDEX IF NOT EXISTS endpoint_inventory_cpe_count_history_cpe_time_idx
      ON #{schema()}.#{@cpe_count_history_table} (cpe, scan_time DESC)
    """)

    set_compression(@cpe_count_history_table, "cpe", "scan_time DESC")
    add_compression_policy(@cpe_count_history_table, @compression_after)
    add_retention_policy(@cpe_count_history_table, @retention_interval)
  end

  defp create_continuous_aggregates do
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

      IF ts_schema IS NULL THEN
        RETURN;
      END IF;

      EXECUTE '
        CREATE MATERIALIZED VIEW IF NOT EXISTS #{schema()}.#{@package_counts_hourly}
        WITH (timescaledb.continuous) AS
        SELECT
          time_bucket(''1 hour'', scan_time) AS bucket,
          coordinate_hash,
          package_manager,
          COALESCE(ecosystem, '''') AS ecosystem,
          name,
          COALESCE(version, '''') AS version,
          COALESCE(architecture, '''') AS architecture,
          COALESCE(purl_canonical, '''') AS purl_canonical,
          MAX(host_count)::integer AS max_host_count,
          MIN(host_count)::integer AS min_host_count,
          SUM(count_delta)::integer AS net_count_delta,
          COUNT(*)::bigint AS sample_count
        FROM #{schema()}.#{@package_count_history_table}
        GROUP BY 1, 2, 3, 4, 5, 6, 7, 8
        WITH NO DATA
      ';

      EXECUTE '
        CREATE MATERIALIZED VIEW IF NOT EXISTS #{schema()}.#{@cpe_counts_hourly}
        WITH (timescaledb.continuous) AS
        SELECT
          time_bucket(''1 hour'', scan_time) AS bucket,
          cpe,
          MAX(host_count)::integer AS max_host_count,
          MIN(host_count)::integer AS min_host_count,
          SUM(count_delta)::integer AS net_count_delta,
          COUNT(*)::bigint AS sample_count
        FROM #{schema()}.#{@cpe_count_history_table}
        GROUP BY 1, 2
        WITH NO DATA
      ';

      EXECUTE 'CREATE INDEX IF NOT EXISTS endpoint_inventory_package_counts_hourly_coord_idx
        ON #{schema()}.#{@package_counts_hourly} (coordinate_hash, bucket DESC)';

      EXECUTE 'CREATE INDEX IF NOT EXISTS endpoint_inventory_package_counts_hourly_name_idx
        ON #{schema()}.#{@package_counts_hourly} (package_manager, name, version, bucket DESC)';

      EXECUTE 'CREATE INDEX IF NOT EXISTS endpoint_inventory_cpe_counts_hourly_cpe_idx
        ON #{schema()}.#{@cpe_counts_hourly} (cpe, bucket DESC)';

      BEGIN
        EXECUTE format(
          'SELECT %I.add_continuous_aggregate_policy(%L::regclass, start_offset => INTERVAL ''31 days'', end_offset => INTERVAL ''5 minutes'', schedule_interval => INTERVAL ''5 minutes'')',
          ts_schema,
          '#{schema()}.#{@package_counts_hourly}'
        );
      EXCEPTION
        WHEN others THEN
          RAISE NOTICE 'Could not add continuous aggregate policy to #{@package_counts_hourly}: %', SQLERRM;
      END;

      BEGIN
        EXECUTE format(
          'SELECT %I.add_continuous_aggregate_policy(%L::regclass, start_offset => INTERVAL ''31 days'', end_offset => INTERVAL ''5 minutes'', schedule_interval => INTERVAL ''5 minutes'')',
          ts_schema,
          '#{schema()}.#{@cpe_counts_hourly}'
        );
      EXCEPTION
        WHEN others THEN
          RAISE NOTICE 'Could not add continuous aggregate policy to #{@cpe_counts_hourly}: %', SQLERRM;
      END;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not create endpoint inventory count continuous aggregates: %', SQLERRM;
    END;
    $$;
    """)
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

  defp drop_continuous_aggregate_policy(view_name) do
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
        EXECUTE format(
          'SELECT %I.remove_continuous_aggregate_policy(%L::regclass, if_exists => true)',
          ts_schema,
          '#{schema()}.#{view_name}'
        );
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not remove continuous aggregate policy from #{view_name}: %', SQLERRM;
    END;
    $$;
    """)
  end
end
