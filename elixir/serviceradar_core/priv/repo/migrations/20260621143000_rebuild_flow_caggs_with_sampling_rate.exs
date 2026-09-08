defmodule ServiceRadar.Repo.Migrations.RebuildFlowCaggsWithSamplingRate do
  @moduledoc false

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @source_table "platform.ocsf_network_activity"
  @traffic_5m "platform.ocsf_network_activity_5m_traffic"
  @proto_view "platform.ocsf_network_activity_hourly_proto"
  @talkers_view "platform.ocsf_network_activity_hourly_talkers"
  @ports_view "platform.ocsf_network_activity_hourly_ports"
  @listeners_view "platform.ocsf_network_activity_hourly_listeners"
  @conversations_view "platform.ocsf_network_activity_hourly_conversations"
  @traffic_1h "platform.flow_traffic_1h"
  @traffic_1d "platform.flow_traffic_1d"

  def up do
    drop_policies()
    drop_flow_caggs()
    create_scaled_flow_caggs()
    create_indexes()
    refresh_flow_caggs()
    add_policies()
  end

  def down do
    drop_policies()
    drop_flow_caggs()
    create_unscaled_flow_caggs()
    create_indexes()
    refresh_flow_caggs()
    add_policies()
  end

  defp drop_policies do
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
        '#{@traffic_1d}',
        '#{@traffic_1h}',
        '#{@conversations_view}',
        '#{@listeners_view}',
        '#{@ports_view}',
        '#{@talkers_view}',
        '#{@proto_view}',
        '#{@traffic_5m}'
      ] LOOP
        BEGIN
          EXECUTE format('SELECT %I.remove_retention_policy(%L::regclass, if_exists => true)', ts_schema, view_ident);
        EXCEPTION WHEN others THEN NULL;
        END;

        BEGIN
          EXECUTE format('SELECT %I.remove_continuous_aggregate_policy(%L::regclass)', ts_schema, view_ident);
        EXCEPTION WHEN others THEN NULL;
        END;
      END LOOP;
    END;
    $$;
    """)
  end

  defp drop_flow_caggs do
    Enum.each(
      [
        @traffic_1d,
        @traffic_1h,
        @conversations_view,
        @listeners_view,
        @ports_view,
        @talkers_view,
        @proto_view,
        @traffic_5m
      ],
      &execute(drop_continuous_view_sql(&1))
    )
  end

  defp drop_continuous_view_sql(view_ident) do
    """
    DO $$
    DECLARE
      backing_table regclass;
    BEGIN
      BEGIN
        EXECUTE 'DROP MATERIALIZED VIEW IF EXISTS #{view_ident} CASCADE';
      EXCEPTION
        WHEN wrong_object_type THEN
          SELECT format('%I.%I', backing_schema.nspname, backing_class.relname)::regclass
          INTO backing_table
          FROM pg_depend dep
          JOIN pg_rewrite rewrite ON rewrite.oid = dep.objid
          JOIN pg_class view_class ON view_class.oid = rewrite.ev_class
          JOIN pg_class backing_class ON backing_class.oid = dep.refobjid
          JOIN pg_namespace backing_schema ON backing_schema.oid = backing_class.relnamespace
          WHERE view_class.oid = '#{view_ident}'::regclass
            AND dep.classid = 'pg_rewrite'::regclass
            AND dep.refclassid = 'pg_class'::regclass
            AND backing_schema.nspname = '_timescaledb_internal'
            AND backing_class.relname LIKE '_materialized_hypertable_%'
          LIMIT 1;

          EXECUTE 'DROP VIEW IF EXISTS #{view_ident} CASCADE';

          IF backing_table IS NOT NULL THEN
            EXECUTE format('DROP TABLE IF EXISTS %s CASCADE', backing_table);
          END IF;
      END;
    END;
    $$;
    """
  end

  defp create_scaled_flow_caggs do
    create_raw_flow_caggs(true)
    create_hierarchical_flow_caggs()
  end

  defp create_unscaled_flow_caggs do
    create_raw_flow_caggs(false)
    create_hierarchical_flow_caggs()
  end

  defp create_raw_flow_caggs(sampled?) do
    ensure_source_hypertable()

    bytes_expr = volume_sum_expr("bytes_total", sampled?)
    packets_expr = volume_sum_expr("packets_total", sampled?)

    execute("""
    CREATE MATERIALIZED VIEW #{@traffic_5m}
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('5 minutes', time) AS bucket,
      #{bytes_expr} AS bytes_total,
      #{packets_expr} AS packets_total,
      COALESCE(COUNT(*), 0)::bigint AS flow_count
    FROM #{@source_table}
    GROUP BY 1
    WITH NO DATA
    """)

    execute("""
    CREATE MATERIALIZED VIEW #{@proto_view}
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('1 hour', time) AS bucket,
      COALESCE(protocol_num, 0) AS protocol_num,
      #{bytes_expr} AS bytes_total,
      #{packets_expr} AS packets_total,
      COALESCE(COUNT(*), 0)::bigint AS flow_count
    FROM #{@source_table}
    GROUP BY 1, 2
    WITH NO DATA
    """)

    execute("""
    CREATE MATERIALIZED VIEW #{@talkers_view}
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('1 hour', time) AS bucket,
      COALESCE(src_endpoint_ip, 'Unknown') AS src_endpoint_ip,
      #{bytes_expr} AS bytes_total,
      #{packets_expr} AS packets_total,
      COALESCE(COUNT(*), 0)::bigint AS flow_count
    FROM #{@source_table}
    GROUP BY 1, 2
    WITH NO DATA
    """)

    execute("""
    CREATE MATERIALIZED VIEW #{@ports_view}
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('1 hour', time) AS bucket,
      COALESCE(dst_endpoint_port, 0) AS dst_endpoint_port,
      #{bytes_expr} AS bytes_total,
      #{packets_expr} AS packets_total,
      COALESCE(COUNT(*), 0)::bigint AS flow_count
    FROM #{@source_table}
    GROUP BY 1, 2
    WITH NO DATA
    """)

    execute("""
    CREATE MATERIALIZED VIEW #{@listeners_view}
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('1 hour', time) AS bucket,
      COALESCE(dst_endpoint_ip, 'Unknown') AS dst_endpoint_ip,
      #{bytes_expr} AS bytes_total,
      #{packets_expr} AS packets_total,
      COALESCE(COUNT(*), 0)::bigint AS flow_count
    FROM #{@source_table}
    GROUP BY 1, 2
    WITH NO DATA
    """)

    execute("""
    CREATE MATERIALIZED VIEW #{@conversations_view}
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('1 hour', time) AS bucket,
      COALESCE(src_endpoint_ip, 'Unknown') AS src_endpoint_ip,
      COALESCE(dst_endpoint_ip, 'Unknown') AS dst_endpoint_ip,
      #{bytes_expr} AS bytes_total,
      #{packets_expr} AS packets_total,
      COALESCE(COUNT(*), 0)::bigint AS flow_count
    FROM #{@source_table}
    GROUP BY 1, 2, 3
    WITH NO DATA
    """)
  end

  defp ensure_source_hypertable do
    execute("""
    DO $$
    DECLARE
      ts_schema text;
      is_hypertable boolean;
    BEGIN
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NULL OR to_regclass('#{@source_table}') IS NULL THEN
        RETURN;
      END IF;

      SELECT EXISTS (
        SELECT 1
        FROM timescaledb_information.hypertables
        WHERE hypertable_schema = 'platform'
          AND hypertable_name = 'ocsf_network_activity'
      )
      INTO is_hypertable;

      IF NOT is_hypertable THEN
        EXECUTE format(
          'SELECT %I.create_hypertable(%L::regclass, %L::name, migrate_data => true, if_not_exists => true)',
          ts_schema,
          '#{@source_table}',
          'time'
        );
      END IF;
    END;
    $$;
    """)
  end

  defp create_hierarchical_flow_caggs do
    execute("""
    CREATE MATERIALIZED VIEW #{@traffic_1h}
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
    CREATE MATERIALIZED VIEW #{@traffic_1d}
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
  end

  defp volume_sum_expr(column, true) do
    "COALESCE(SUM(#{column}::numeric * GREATEST(COALESCE(sampling_rate, 1), 1)::numeric), 0)::bigint"
  end

  defp volume_sum_expr(column, false), do: "COALESCE(SUM(#{column}), 0)::bigint"

  defp create_indexes do
    execute(
      "CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_5m_traffic_bucket ON #{@traffic_5m} (bucket)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_hourly_proto_bucket_proto ON #{@proto_view} (bucket, protocol_num)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_hourly_proto_bucket ON #{@proto_view} (bucket DESC)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_hourly_talkers_bucket_ip ON #{@talkers_view} (bucket, src_endpoint_ip)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_hourly_talkers_bucket ON #{@talkers_view} (bucket DESC)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_hourly_talkers_ip ON #{@talkers_view} (src_endpoint_ip)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_hourly_ports_bucket_port ON #{@ports_view} (bucket, dst_endpoint_port)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_hourly_ports_bucket ON #{@ports_view} (bucket DESC)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_hourly_ports_port ON #{@ports_view} (dst_endpoint_port)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS idx_hourly_listeners_bucket ON #{@listeners_view} (bucket DESC)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS idx_hourly_listeners_ip ON #{@listeners_view} (dst_endpoint_ip)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS idx_hourly_conversations_bucket ON #{@conversations_view} (bucket DESC)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS idx_hourly_conversations_pair ON #{@conversations_view} (src_endpoint_ip, dst_endpoint_ip)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS idx_flow_traffic_1h_bucket ON #{@traffic_1h} (bucket DESC)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS idx_flow_traffic_1d_bucket ON #{@traffic_1d} (bucket DESC)"
    )
  end

  defp refresh_flow_caggs do
    execute("""
    DO $$
    BEGIN
      IF to_regprocedure('refresh_continuous_aggregate(regclass,timestamptz,timestamptz)') IS NOT NULL
         OR to_regprocedure('refresh_continuous_aggregate(regclass,timestamp without time zone,timestamp without time zone)') IS NOT NULL THEN
        BEGIN
          CALL refresh_continuous_aggregate('#{@traffic_5m}', now() - INTERVAL '31 days', now());
        EXCEPTION WHEN others THEN NULL;
        END;

        BEGIN
          CALL refresh_continuous_aggregate('#{@proto_view}', now() - INTERVAL '31 days', now());
        EXCEPTION WHEN others THEN NULL;
        END;

        BEGIN
          CALL refresh_continuous_aggregate('#{@talkers_view}', now() - INTERVAL '31 days', now());
        EXCEPTION WHEN others THEN NULL;
        END;

        BEGIN
          CALL refresh_continuous_aggregate('#{@ports_view}', now() - INTERVAL '31 days', now());
        EXCEPTION WHEN others THEN NULL;
        END;

        BEGIN
          CALL refresh_continuous_aggregate('#{@listeners_view}', now() - INTERVAL '7 days', now());
        EXCEPTION WHEN others THEN NULL;
        END;

        BEGIN
          CALL refresh_continuous_aggregate('#{@conversations_view}', now() - INTERVAL '7 days', now());
        EXCEPTION WHEN others THEN NULL;
        END;

        BEGIN
          CALL refresh_continuous_aggregate('#{@traffic_1h}', now() - INTERVAL '7 days', now());
        EXCEPTION WHEN others THEN NULL;
        END;

        BEGIN
          CALL refresh_continuous_aggregate('#{@traffic_1d}', now() - INTERVAL '30 days', now());
        EXCEPTION WHEN others THEN NULL;
        END;
      END IF;
    END;
    $$;
    """)
  end

  defp add_policies do
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
        '#{@traffic_5m}',
        '#{@proto_view}',
        '#{@talkers_view}',
        '#{@ports_view}'
      ] LOOP
        BEGIN
          EXECUTE format(
            'SELECT %I.add_continuous_aggregate_policy(%L::regclass, start_offset => INTERVAL ''31 days'', end_offset => INTERVAL ''5 minutes'', schedule_interval => INTERVAL ''5 minutes'')',
            ts_schema,
            view_ident
          );
        EXCEPTION WHEN others THEN NULL;
        END;

        BEGIN
          EXECUTE format(
            'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''30 days'', if_not_exists => true)',
            ts_schema,
            view_ident
          );
        EXCEPTION WHEN others THEN NULL;
        END;
      END LOOP;

      FOREACH view_ident IN ARRAY ARRAY[
        '#{@listeners_view}',
        '#{@conversations_view}'
      ] LOOP
        BEGIN
          EXECUTE format(
            'SELECT %I.add_continuous_aggregate_policy(%L::regclass, start_offset => INTERVAL ''31 days'', end_offset => INTERVAL ''5 minutes'', schedule_interval => INTERVAL ''5 minutes'')',
            ts_schema,
            view_ident
          );
        EXCEPTION WHEN others THEN NULL;
        END;

        BEGIN
          EXECUTE format(
            'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''90 days'', if_not_exists => true)',
            ts_schema,
            view_ident
          );
        EXCEPTION WHEN others THEN NULL;
        END;
      END LOOP;

      BEGIN
        EXECUTE format(
          'SELECT %I.add_continuous_aggregate_policy(%L::regclass, start_offset => INTERVAL ''2 hours'', end_offset => INTERVAL ''1 hour'', schedule_interval => INTERVAL ''1 hour'')',
          ts_schema,
          '#{@traffic_1h}'
        );
      EXCEPTION WHEN others THEN NULL;
      END;

      BEGIN
        EXECUTE format(
          'SELECT %I.add_continuous_aggregate_policy(%L::regclass, start_offset => INTERVAL ''2 days'', end_offset => INTERVAL ''1 day'', schedule_interval => INTERVAL ''1 day'')',
          ts_schema,
          '#{@traffic_1d}'
        );
      EXCEPTION WHEN others THEN NULL;
      END;

      FOREACH view_ident IN ARRAY ARRAY[
        '#{@traffic_1h}',
        '#{@traffic_1d}'
      ] LOOP
        BEGIN
          EXECUTE format(
            'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''365 days'', if_not_exists => true)',
            ts_schema,
            view_ident
          );
        EXCEPTION WHEN others THEN NULL;
        END;
      END LOOP;
    END;
    $$;
    """)
  end
end
