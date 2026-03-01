defmodule ServiceRadar.Repo.Migrations.AddOcsfNetworkActivityRollups do
  @moduledoc """
  Creates TimescaleDB continuous aggregates (CAGGs) for flow telemetry.

  These rollups are intended to back NetFlow dashboard widgets:
  - traffic over time
  - protocol distribution
  - top talkers
  - top destination ports

  Note: continuous aggregates are created WITH DATA and must not run inside a transaction.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @source_table "platform.ocsf_network_activity"

  @traffic_view "platform.ocsf_network_activity_5m_traffic"
  @proto_view "platform.ocsf_network_activity_hourly_proto"
  @talkers_view "platform.ocsf_network_activity_hourly_talkers"
  @ports_view "platform.ocsf_network_activity_hourly_ports"

  # Keep rollups longer than raw flows.
  @retention_interval "30 days"
  @refresh_start_offset "31 days"
  @refresh_end_offset "5 minutes"
  @refresh_interval "5 minutes"

  def up do
    execute("""
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{@traffic_view}
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('5 minutes', time) AS bucket,
      COALESCE(SUM(bytes_total), 0)::bigint AS bytes_total,
      COALESCE(SUM(packets_total), 0)::bigint AS packets_total,
      COALESCE(COUNT(*), 0)::bigint AS flow_count
    FROM #{@source_table}
    GROUP BY 1
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_5m_traffic_bucket
    ON #{@traffic_view} (bucket)
    """)

    execute("""
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{@proto_view}
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('1 hour', time) AS bucket,
      COALESCE(protocol_num, 0) AS protocol_num,
      COALESCE(SUM(bytes_total), 0)::bigint AS bytes_total,
      COALESCE(SUM(packets_total), 0)::bigint AS packets_total,
      COALESCE(COUNT(*), 0)::bigint AS flow_count
    FROM #{@source_table}
    GROUP BY 1, 2
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_hourly_proto_bucket_proto
    ON #{@proto_view} (bucket, protocol_num)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_hourly_proto_bucket
    ON #{@proto_view} (bucket DESC)
    """)

    execute("""
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{@talkers_view}
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('1 hour', time) AS bucket,
      COALESCE(src_endpoint_ip, 'Unknown') AS src_endpoint_ip,
      COALESCE(SUM(bytes_total), 0)::bigint AS bytes_total,
      COALESCE(SUM(packets_total), 0)::bigint AS packets_total,
      COALESCE(COUNT(*), 0)::bigint AS flow_count
    FROM #{@source_table}
    GROUP BY 1, 2
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_hourly_talkers_bucket_ip
    ON #{@talkers_view} (bucket, src_endpoint_ip)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_hourly_talkers_bucket
    ON #{@talkers_view} (bucket DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_hourly_talkers_ip
    ON #{@talkers_view} (src_endpoint_ip)
    """)

    execute("""
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{@ports_view}
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('1 hour', time) AS bucket,
      COALESCE(dst_endpoint_port, 0) AS dst_endpoint_port,
      COALESCE(SUM(bytes_total), 0)::bigint AS bytes_total,
      COALESCE(SUM(packets_total), 0)::bigint AS packets_total,
      COALESCE(COUNT(*), 0)::bigint AS flow_count
    FROM #{@source_table}
    GROUP BY 1, 2
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_hourly_ports_bucket_port
    ON #{@ports_view} (bucket, dst_endpoint_port)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_hourly_ports_bucket
    ON #{@ports_view} (bucket DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_hourly_ports_port
    ON #{@ports_view} (dst_endpoint_port)
    """)

    # Policies + retention (best-effort).
    execute("""
    DO $$
    DECLARE
      ts_schema text;
      view_ident text;
    BEGIN
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NULL THEN
        RETURN;
      END IF;

      FOREACH view_ident IN ARRAY ARRAY[
        '#{@traffic_view}',
        '#{@proto_view}',
        '#{@talkers_view}',
        '#{@ports_view}'
      ] LOOP
        BEGIN
          EXECUTE format(
            'SELECT %I.add_continuous_aggregate_policy(%L::regclass, '
            'start_offset => INTERVAL ''#{@refresh_start_offset}'', '
            'end_offset => INTERVAL ''#{@refresh_end_offset}'', '
            'schedule_interval => INTERVAL ''#{@refresh_interval}'')',
            ts_schema,
            view_ident
          );
        EXCEPTION
          WHEN others THEN
            NULL;
        END;

        BEGIN
          EXECUTE format(
            'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''#{@retention_interval}'', if_not_exists => true)',
            ts_schema,
            view_ident
          );
        EXCEPTION
          WHEN others THEN
            NULL;
        END;
      END LOOP;
    END;
    $$;
    """)
  end

  def down do
    execute("""
    DO $$
    DECLARE
      ts_schema text;
      view_ident text;
    BEGIN
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NOT NULL THEN
        FOREACH view_ident IN ARRAY ARRAY[
          '#{@traffic_view}',
          '#{@proto_view}',
          '#{@talkers_view}',
          '#{@ports_view}'
        ] LOOP
          BEGIN
            EXECUTE format(
              'SELECT %I.remove_retention_policy(%L::regclass, if_exists => true)',
              ts_schema,
              view_ident
            );
          EXCEPTION
            WHEN others THEN
              NULL;
          END;

          BEGIN
            EXECUTE format(
              'SELECT %I.remove_continuous_aggregate_policy(%L::regclass)',
              ts_schema,
              view_ident
            );
          EXCEPTION
            WHEN others THEN
              NULL;
          END;
        END LOOP;
      END IF;
    END;
    $$;
    """)

    execute("DROP MATERIALIZED VIEW IF EXISTS #{@traffic_view}")
    execute("DROP MATERIALIZED VIEW IF EXISTS #{@proto_view}")
    execute("DROP MATERIALIZED VIEW IF EXISTS #{@talkers_view}")
    execute("DROP MATERIALIZED VIEW IF EXISTS #{@ports_view}")

    execute("DROP INDEX IF EXISTS platform.idx_ocsf_network_activity_5m_traffic_bucket")
    execute("DROP INDEX IF EXISTS platform.idx_ocsf_network_activity_hourly_proto_bucket_proto")
    execute("DROP INDEX IF EXISTS platform.idx_ocsf_network_activity_hourly_proto_bucket")
    execute("DROP INDEX IF EXISTS platform.idx_ocsf_network_activity_hourly_talkers_bucket_ip")
    execute("DROP INDEX IF EXISTS platform.idx_ocsf_network_activity_hourly_talkers_bucket")
    execute("DROP INDEX IF EXISTS platform.idx_ocsf_network_activity_hourly_talkers_ip")
    execute("DROP INDEX IF EXISTS platform.idx_ocsf_network_activity_hourly_ports_bucket_port")
    execute("DROP INDEX IF EXISTS platform.idx_ocsf_network_activity_hourly_ports_bucket")
    execute("DROP INDEX IF EXISTS platform.idx_ocsf_network_activity_hourly_ports_port")
  end
end
