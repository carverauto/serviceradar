defmodule ServiceRadar.Repo.Migrations.AddFlowTrafficHierarchicalCaggs do
  @moduledoc """
  Adds hierarchical continuous aggregates for flow traffic analysis:

  - 1-hour traffic CAGG (from existing 5-minute traffic CAGG)
  - 1-day traffic CAGG (from 1-hour traffic CAGG)
  - Hourly listeners CAGG (by dst_endpoint_ip)
  - Hourly conversations CAGG (by src_endpoint_ip + dst_endpoint_ip)

  These support the flows dashboard homepage for capacity planning queries
  over long time windows (7d, 30d) without scanning raw data.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @source_table "platform.ocsf_network_activity"
  @traffic_5m "platform.ocsf_network_activity_5m_traffic"

  @traffic_1h "platform.flow_traffic_1h"
  @traffic_1d "platform.flow_traffic_1d"
  @listeners_view "platform.ocsf_network_activity_hourly_listeners"
  @conversations_view "platform.ocsf_network_activity_hourly_conversations"

  # Retention and refresh settings
  @retention_interval "90 days"

  def up do
    # 1-hour traffic CAGG (hierarchical from 5-minute CAGG)
    execute("""
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{@traffic_1h}
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('1 hour', bucket) AS bucket,
      SUM(bytes_total)::bigint AS bytes_total,
      SUM(packets_total)::bigint AS packets_total,
      SUM(flow_count)::bigint AS flow_count
    FROM #{@traffic_5m}
    GROUP BY 1
    WITH NO DATA
    """)

    execute("""
    DO $$
    BEGIN
      IF to_regprocedure('refresh_continuous_aggregate(regclass,timestamptz,timestamptz)') IS NOT NULL THEN
        CALL refresh_continuous_aggregate('#{@traffic_1h}', now() - INTERVAL '7 days', now());
      END IF;
    END;
    $$;
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_flow_traffic_1h_bucket
    ON #{@traffic_1h} (bucket DESC)
    """)

    # 1-day traffic CAGG (hierarchical from 1-hour CAGG)
    execute("""
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{@traffic_1d}
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('1 day', bucket) AS bucket,
      SUM(bytes_total)::bigint AS bytes_total,
      SUM(packets_total)::bigint AS packets_total,
      SUM(flow_count)::bigint AS flow_count
    FROM #{@traffic_1h}
    GROUP BY 1
    WITH NO DATA
    """)

    execute("""
    DO $$
    BEGIN
      IF to_regprocedure('refresh_continuous_aggregate(regclass,timestamptz,timestamptz)') IS NOT NULL THEN
        CALL refresh_continuous_aggregate('#{@traffic_1d}', now() - INTERVAL '30 days', now());
      END IF;
    END;
    $$;
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_flow_traffic_1d_bucket
    ON #{@traffic_1d} (bucket DESC)
    """)

    # Hourly listeners CAGG (by destination IP)
    execute("""
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{@listeners_view}
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('1 hour', time) AS bucket,
      COALESCE(dst_endpoint_ip, 'Unknown') AS dst_endpoint_ip,
      COALESCE(SUM(bytes_total), 0)::bigint AS bytes_total,
      COALESCE(SUM(packets_total), 0)::bigint AS packets_total,
      COALESCE(COUNT(*), 0)::bigint AS flow_count
    FROM #{@source_table}
    GROUP BY 1, 2
    WITH NO DATA
    """)

    execute("""
    DO $$
    BEGIN
      IF to_regprocedure('refresh_continuous_aggregate(regclass,timestamptz,timestamptz)') IS NOT NULL THEN
        CALL refresh_continuous_aggregate('#{@listeners_view}', now() - INTERVAL '7 days', now());
      END IF;
    END;
    $$;
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_hourly_listeners_bucket
    ON #{@listeners_view} (bucket DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_hourly_listeners_ip
    ON #{@listeners_view} (dst_endpoint_ip)
    """)

    # Hourly conversations CAGG (by src + dst IP pair)
    execute("""
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{@conversations_view}
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('1 hour', time) AS bucket,
      COALESCE(src_endpoint_ip, 'Unknown') AS src_endpoint_ip,
      COALESCE(dst_endpoint_ip, 'Unknown') AS dst_endpoint_ip,
      COALESCE(SUM(bytes_total), 0)::bigint AS bytes_total,
      COALESCE(SUM(packets_total), 0)::bigint AS packets_total,
      COALESCE(COUNT(*), 0)::bigint AS flow_count
    FROM #{@source_table}
    GROUP BY 1, 2, 3
    WITH NO DATA
    """)

    execute("""
    DO $$
    BEGIN
      IF to_regprocedure('refresh_continuous_aggregate(regclass,timestamptz,timestamptz)') IS NOT NULL THEN
        CALL refresh_continuous_aggregate('#{@conversations_view}', now() - INTERVAL '7 days', now());
      END IF;
    END;
    $$;
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_hourly_conversations_bucket
    ON #{@conversations_view} (bucket DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_hourly_conversations_pair
    ON #{@conversations_view} (src_endpoint_ip, dst_endpoint_ip)
    """)

    # Add refresh policies and retention (best-effort)
    execute("""
    DO $$
    DECLARE
      ts_schema text;
      view_ident text;
      refresh_cfg record;
    BEGIN
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NULL THEN
        RETURN;
      END IF;

      -- 1h traffic: refresh every hour, look back 2 hours
      BEGIN
        EXECUTE format(
          'SELECT %I.add_continuous_aggregate_policy(%L::regclass, '
          'start_offset => INTERVAL ''2 hours'', '
          'end_offset => INTERVAL ''1 hour'', '
          'schedule_interval => INTERVAL ''1 hour'')',
          ts_schema, '#{@traffic_1h}'
        );
      EXCEPTION WHEN others THEN NULL;
      END;

      -- 1d traffic: refresh every day, look back 2 days
      BEGIN
        EXECUTE format(
          'SELECT %I.add_continuous_aggregate_policy(%L::regclass, '
          'start_offset => INTERVAL ''2 days'', '
          'end_offset => INTERVAL ''1 day'', '
          'schedule_interval => INTERVAL ''1 day'')',
          ts_schema, '#{@traffic_1d}'
        );
      EXCEPTION WHEN others THEN NULL;
      END;

      -- Hourly listeners + conversations: same as existing hourly CAGGs
      FOREACH view_ident IN ARRAY ARRAY[
        '#{@listeners_view}',
        '#{@conversations_view}'
      ] LOOP
        BEGIN
          EXECUTE format(
            'SELECT %I.add_continuous_aggregate_policy(%L::regclass, '
            'start_offset => INTERVAL ''31 days'', '
            'end_offset => INTERVAL ''5 minutes'', '
            'schedule_interval => INTERVAL ''5 minutes'')',
            ts_schema, view_ident
          );
        EXCEPTION WHEN others THEN NULL;
        END;

        BEGIN
          EXECUTE format(
            'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''#{@retention_interval}'', if_not_exists => true)',
            ts_schema, view_ident
          );
        EXCEPTION WHEN others THEN NULL;
        END;
      END LOOP;

      -- Retention for hierarchical traffic CAGGs
      FOREACH view_ident IN ARRAY ARRAY[
        '#{@traffic_1h}',
        '#{@traffic_1d}'
      ] LOOP
        BEGIN
          EXECUTE format(
            'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''365 days'', if_not_exists => true)',
            ts_schema, view_ident
          );
        EXCEPTION WHEN others THEN NULL;
        END;
      END LOOP;
    END;
    $$;
    """)
  end

  def down do
    execute("DROP MATERIALIZED VIEW IF EXISTS #{@traffic_1d} CASCADE")
    execute("DROP MATERIALIZED VIEW IF EXISTS #{@traffic_1h} CASCADE")
    execute("DROP MATERIALIZED VIEW IF EXISTS #{@conversations_view} CASCADE")
    execute("DROP MATERIALIZED VIEW IF EXISTS #{@listeners_view} CASCADE")
  end
end
