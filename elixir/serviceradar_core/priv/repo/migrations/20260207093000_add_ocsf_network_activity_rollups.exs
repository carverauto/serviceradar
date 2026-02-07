defmodule ServiceRadar.Repo.Migrations.AddOcsfNetworkActivityRollups do
  @moduledoc """
  Creates TimescaleDB continuous aggregates (CAGGs) for flow telemetry.

  These rollups are intended to back NetFlow dashboard widgets:
  - traffic over time
  - protocol distribution
  - top talkers
  - top destination ports

  This migration is idempotent and safe to re-run. If TimescaleDB is not
  available, this becomes a no-op.
  """
  use Ecto.Migration

  @source_table "ocsf_network_activity"

  @traffic_view "ocsf_network_activity_5m_traffic"
  @proto_view "ocsf_network_activity_hourly_proto"
  @talkers_view "ocsf_network_activity_hourly_talkers"
  @ports_view "ocsf_network_activity_hourly_ports"

  # Keep rollups longer than raw flows.
  @retention_interval "30 days"
  @refresh_start_offset "31 days"
  @refresh_end_offset "5 minutes"
  @refresh_interval "5 minutes"

  def up do
    execute("""
    DO $$
    DECLARE
      ts_schema text;
      source_exists boolean;
      view_ident text;
    BEGIN
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NULL THEN
        RAISE NOTICE 'TimescaleDB extension not available, skipping OCSF network_activity rollups';
        RETURN;
      END IF;

      SELECT EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = '#{prefix()}'
          AND c.relname = '#{@source_table}'
      ) INTO source_exists;

      IF NOT source_exists THEN
        RAISE NOTICE 'Source table #{@source_table} missing, skipping rollups';
        RETURN;
      END IF;

      -- 5-minute traffic rollup (bytes/packets/flows)
      EXECUTE format(
        'CREATE MATERIALIZED VIEW IF NOT EXISTS %I.%I WITH (timescaledb.continuous) AS '
        'SELECT time_bucket(''5 minutes'', time) AS bucket, '
        'COALESCE(SUM(bytes_total), 0)::bigint AS bytes_total, '
        'COALESCE(SUM(packets_total), 0)::bigint AS packets_total, '
        'COALESCE(COUNT(*), 0)::bigint AS flow_count '
        'FROM %I.%I '
        'GROUP BY 1',
        '#{prefix()}',
        '#{@traffic_view}',
        '#{prefix()}',
        '#{@source_table}'
      );

      EXECUTE format(
        'CREATE UNIQUE INDEX IF NOT EXISTS %I ON %I.%I (bucket)',
        'idx_ocsf_network_activity_5m_traffic_bucket',
        '#{prefix()}',
        '#{@traffic_view}'
      );

      -- Hourly protocol rollup
      EXECUTE format(
        'CREATE MATERIALIZED VIEW IF NOT EXISTS %I.%I WITH (timescaledb.continuous) AS '
        'SELECT time_bucket(''1 hour'', time) AS bucket, '
        'COALESCE(protocol_num, 0) AS protocol_num, '
        'COALESCE(SUM(bytes_total), 0)::bigint AS bytes_total, '
        'COALESCE(SUM(packets_total), 0)::bigint AS packets_total, '
        'COALESCE(COUNT(*), 0)::bigint AS flow_count '
        'FROM %I.%I '
        'GROUP BY 1, 2',
        '#{prefix()}',
        '#{@proto_view}',
        '#{prefix()}',
        '#{@source_table}'
      );

      EXECUTE format(
        'CREATE UNIQUE INDEX IF NOT EXISTS %I ON %I.%I (bucket, protocol_num)',
        'idx_ocsf_network_activity_hourly_proto_bucket_proto',
        '#{prefix()}',
        '#{@proto_view}'
      );

      EXECUTE format(
        'CREATE INDEX IF NOT EXISTS %I ON %I.%I (bucket DESC)',
        'idx_ocsf_network_activity_hourly_proto_bucket',
        '#{prefix()}',
        '#{@proto_view}'
      );

      -- Hourly top talkers rollup (grouped by source IP)
      EXECUTE format(
        'CREATE MATERIALIZED VIEW IF NOT EXISTS %I.%I WITH (timescaledb.continuous) AS '
        'SELECT time_bucket(''1 hour'', time) AS bucket, '
        'COALESCE(src_endpoint_ip, ''Unknown'') AS src_endpoint_ip, '
        'COALESCE(SUM(bytes_total), 0)::bigint AS bytes_total, '
        'COALESCE(SUM(packets_total), 0)::bigint AS packets_total, '
        'COALESCE(COUNT(*), 0)::bigint AS flow_count '
        'FROM %I.%I '
        'GROUP BY 1, 2',
        '#{prefix()}',
        '#{@talkers_view}',
        '#{prefix()}',
        '#{@source_table}'
      );

      EXECUTE format(
        'CREATE UNIQUE INDEX IF NOT EXISTS %I ON %I.%I (bucket, src_endpoint_ip)',
        'idx_ocsf_network_activity_hourly_talkers_bucket_ip',
        '#{prefix()}',
        '#{@talkers_view}'
      );

      EXECUTE format(
        'CREATE INDEX IF NOT EXISTS %I ON %I.%I (bucket DESC)',
        'idx_ocsf_network_activity_hourly_talkers_bucket',
        '#{prefix()}',
        '#{@talkers_view}'
      );

      EXECUTE format(
        'CREATE INDEX IF NOT EXISTS %I ON %I.%I (src_endpoint_ip)',
        'idx_ocsf_network_activity_hourly_talkers_ip',
        '#{prefix()}',
        '#{@talkers_view}'
      );

      -- Hourly top destination ports rollup
      EXECUTE format(
        'CREATE MATERIALIZED VIEW IF NOT EXISTS %I.%I WITH (timescaledb.continuous) AS '
        'SELECT time_bucket(''1 hour'', time) AS bucket, '
        'COALESCE(dst_endpoint_port, 0) AS dst_endpoint_port, '
        'COALESCE(SUM(bytes_total), 0)::bigint AS bytes_total, '
        'COALESCE(SUM(packets_total), 0)::bigint AS packets_total, '
        'COALESCE(COUNT(*), 0)::bigint AS flow_count '
        'FROM %I.%I '
        'GROUP BY 1, 2',
        '#{prefix()}',
        '#{@ports_view}',
        '#{prefix()}',
        '#{@source_table}'
      );

      EXECUTE format(
        'CREATE UNIQUE INDEX IF NOT EXISTS %I ON %I.%I (bucket, dst_endpoint_port)',
        'idx_ocsf_network_activity_hourly_ports_bucket_port',
        '#{prefix()}',
        '#{@ports_view}'
      );

      EXECUTE format(
        'CREATE INDEX IF NOT EXISTS %I ON %I.%I (bucket DESC)',
        'idx_ocsf_network_activity_hourly_ports_bucket',
        '#{prefix()}',
        '#{@ports_view}'
      );

      EXECUTE format(
        'CREATE INDEX IF NOT EXISTS %I ON %I.%I (dst_endpoint_port)',
        'idx_ocsf_network_activity_hourly_ports_port',
        '#{prefix()}',
        '#{@ports_view}'
      );

      -- Policies + retention (best-effort)
      -- traffic view
      view_ident := format('%I.%I', '#{prefix()}', '#{@traffic_view}');
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
          RAISE NOTICE 'Could not add continuous aggregate policy to #{@traffic_view}: %', SQLERRM;
      END;

      BEGIN
        EXECUTE format(
          'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''#{@retention_interval}'', if_not_exists => true)',
          ts_schema,
          view_ident
        );
      EXCEPTION
        WHEN others THEN
          RAISE NOTICE 'Could not add retention policy to #{@traffic_view}: %', SQLERRM;
      END;

      -- proto view
      view_ident := format('%I.%I', '#{prefix()}', '#{@proto_view}');
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
          RAISE NOTICE 'Could not add continuous aggregate policy to #{@proto_view}: %', SQLERRM;
      END;

      BEGIN
        EXECUTE format(
          'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''#{@retention_interval}'', if_not_exists => true)',
          ts_schema,
          view_ident
        );
      EXCEPTION
        WHEN others THEN
          RAISE NOTICE 'Could not add retention policy to #{@proto_view}: %', SQLERRM;
      END;

      -- talkers view
      view_ident := format('%I.%I', '#{prefix()}', '#{@talkers_view}');
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
          RAISE NOTICE 'Could not add continuous aggregate policy to #{@talkers_view}: %', SQLERRM;
      END;

      BEGIN
        EXECUTE format(
          'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''#{@retention_interval}'', if_not_exists => true)',
          ts_schema,
          view_ident
        );
      EXCEPTION
        WHEN others THEN
          RAISE NOTICE 'Could not add retention policy to #{@talkers_view}: %', SQLERRM;
      END;

      -- ports view
      view_ident := format('%I.%I', '#{prefix()}', '#{@ports_view}');
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
          RAISE NOTICE 'Could not add continuous aggregate policy to #{@ports_view}: %', SQLERRM;
      END;

      BEGIN
        EXECUTE format(
          'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''#{@retention_interval}'', if_not_exists => true)',
          ts_schema,
          view_ident
        );
      EXCEPTION
        WHEN others THEN
          RAISE NOTICE 'Could not add retention policy to #{@ports_view}: %', SQLERRM;
      END;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not create OCSF network_activity rollups: %', SQLERRM;
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

      -- Best-effort removal of policies; dropping the view is the main goal.
      IF ts_schema IS NOT NULL THEN
        FOREACH view_ident IN ARRAY ARRAY[
          format('%I.%I', '#{prefix()}', '#{@traffic_view}'),
          format('%I.%I', '#{prefix()}', '#{@proto_view}'),
          format('%I.%I', '#{prefix()}', '#{@talkers_view}'),
          format('%I.%I', '#{prefix()}', '#{@ports_view}')
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

      EXECUTE format('DROP MATERIALIZED VIEW IF EXISTS %I.%I', '#{prefix()}', '#{@traffic_view}');
      EXECUTE format('DROP MATERIALIZED VIEW IF EXISTS %I.%I', '#{prefix()}', '#{@proto_view}');
      EXECUTE format('DROP MATERIALIZED VIEW IF EXISTS %I.%I', '#{prefix()}', '#{@talkers_view}');
      EXECUTE format('DROP MATERIALIZED VIEW IF EXISTS %I.%I', '#{prefix()}', '#{@ports_view}');

      EXECUTE format('DROP INDEX IF EXISTS %I.%I', '#{prefix()}', 'idx_ocsf_network_activity_5m_traffic_bucket');
      EXECUTE format('DROP INDEX IF EXISTS %I.%I', '#{prefix()}', 'idx_ocsf_network_activity_hourly_proto_bucket_proto');
      EXECUTE format('DROP INDEX IF EXISTS %I.%I', '#{prefix()}', 'idx_ocsf_network_activity_hourly_proto_bucket');
      EXECUTE format('DROP INDEX IF EXISTS %I.%I', '#{prefix()}', 'idx_ocsf_network_activity_hourly_talkers_bucket_ip');
      EXECUTE format('DROP INDEX IF EXISTS %I.%I', '#{prefix()}', 'idx_ocsf_network_activity_hourly_talkers_bucket');
      EXECUTE format('DROP INDEX IF EXISTS %I.%I', '#{prefix()}', 'idx_ocsf_network_activity_hourly_talkers_ip');
      EXECUTE format('DROP INDEX IF EXISTS %I.%I', '#{prefix()}', 'idx_ocsf_network_activity_hourly_ports_bucket_port');
      EXECUTE format('DROP INDEX IF EXISTS %I.%I', '#{prefix()}', 'idx_ocsf_network_activity_hourly_ports_bucket');
      EXECUTE format('DROP INDEX IF EXISTS %I.%I', '#{prefix()}', 'idx_ocsf_network_activity_hourly_ports_port');
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not drop OCSF network_activity rollups: %', SQLERRM;
    END;
    $$;
    """)
  end
end

