defmodule ServiceRadar.Repo.Migrations.DropCnpgFlowHypertableAndCaggs do
  @moduledoc """
  Drops the retired CNPG flow hypertable (`platform.ocsf_network_activity`) and
  its continuous aggregates (`#5747`).

  Flows (`in:flows` and `in:attributed_flows`) are warehouse-only datasets stored
  in StarRocks. Removing the legacy CNPG hypertable and continuous aggregates
  eliminates unused TimescaleDB background policies, continuous aggregate
  materialization tables, and schema drift on fresh and upgraded installations.

  serviceradar:allow-startup-maintenance - dropping retired continuous aggregate
  views, policies, and the empty/retired flow hypertable is bounded DDL cleanup.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @flow_caggs [
    "platform.flow_traffic_1d",
    "platform.flow_traffic_1h",
    "platform.ocsf_network_activity_hourly_conversations",
    "platform.ocsf_network_activity_hourly_listeners",
    "platform.ocsf_network_activity_hourly_ports",
    "platform.ocsf_network_activity_hourly_proto",
    "platform.ocsf_network_activity_hourly_talkers",
    "platform.ocsf_network_activity_5m_traffic"
  ]

  @source_table "platform.ocsf_network_activity"

  def up do
    drop_policies()
    Enum.each(@flow_caggs, &execute(drop_continuous_view_sql(&1)))
    execute("DROP TABLE IF EXISTS #{@source_table} CASCADE")
    cleanup_cold_tier_state()
  end

  def down, do: :ok

  defp drop_policies do
    cagg_list = Enum.map_join(@flow_caggs, ", ", &"'#{&1}'")

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

      FOREACH view_ident IN ARRAY ARRAY[#{cagg_list}] LOOP
        IF to_regclass(view_ident) IS NOT NULL THEN
          BEGIN
            EXECUTE format('SELECT %I.remove_retention_policy(%L::regclass, if_exists => true)', ts_schema, view_ident);
          EXCEPTION WHEN others THEN NULL;
          END;

          BEGIN
            EXECUTE format('SELECT %I.remove_continuous_aggregate_policy(%L::regclass, if_exists => true)', ts_schema, view_ident);
          EXCEPTION WHEN others THEN NULL;
          END;
        END IF;
      END LOOP;

      IF to_regclass('#{@source_table}') IS NOT NULL THEN
        BEGIN
          EXECUTE format('SELECT %I.remove_retention_policy(%L::regclass, if_exists => true)', ts_schema, '#{@source_table}');
        EXCEPTION WHEN others THEN NULL;
        END;

        BEGIN
          EXECUTE format('SELECT %I.remove_compression_policy(%L::regclass, if_exists => true)', ts_schema, '#{@source_table}');
        EXCEPTION WHEN others THEN NULL;
        END;
      END IF;
    END;
    $$;
    """)
  end

  defp drop_continuous_view_sql(view_ident) do
    """
    DO $$
    DECLARE
      backing_table regclass;
    BEGIN
      IF to_regclass('#{view_ident}') IS NULL THEN
        RETURN;
      END IF;

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

  defp cleanup_cold_tier_state do
    execute("""
    DO $$
    BEGIN
      IF to_regclass('platform.cold_chunk_exports') IS NOT NULL THEN
        DELETE FROM platform.cold_chunk_exports
        WHERE table_name = 'ocsf_network_activity'
          AND status <> 'verified';
      END IF;

      IF to_regclass('platform.cold_tier_boundaries') IS NOT NULL THEN
        DELETE FROM platform.cold_tier_boundaries
        WHERE table_name = 'ocsf_network_activity'
          AND NOT EXISTS (
            SELECT 1
            FROM platform.cold_chunk_exports
            WHERE table_name = 'ocsf_network_activity'
              AND status = 'verified'
          );
      END IF;
    END;
    $$;
    """)
  end
end
