defmodule ServiceRadar.Repo.Migrations.EnsureOcsfEventsHourlyStats do
  @moduledoc """
  Ensures the OCSF hourly events CAGG exists for environments that may have
  skipped creation during the initial migration.
  """
  use Ecto.Migration

  @view "ocsf_events_hourly_stats"
  @source_table "ocsf_events"
  @retention_interval "24 hours"
  @refresh_start_offset "26 hours"
  @refresh_end_offset "5 minutes"
  @refresh_interval "5 minutes"

  def up do
    execute("""
    DO $$
    DECLARE
      ts_schema text;
      view_ident text;
      source_exists boolean;
      policy_exists boolean;
    BEGIN
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NULL THEN
        RAISE NOTICE 'TimescaleDB extension not available, skipping #{@view}';
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
        RAISE NOTICE 'Source table #{@source_table} missing, skipping #{@view}';
        RETURN;
      END IF;

      view_ident := format('%I.%I', '#{prefix()}', '#{@view}');

      EXECUTE format(
        'CREATE MATERIALIZED VIEW IF NOT EXISTS %I.%I WITH (timescaledb.continuous) AS '
        'SELECT time_bucket(''1 hour'', time) AS bucket, '
        'COALESCE(severity_id, 0) AS severity_id, '
        'COUNT(*)::bigint AS total_count '
        'FROM %I.%I '
        'GROUP BY 1, 2',
        '#{prefix()}',
        '#{@view}',
        '#{prefix()}',
        '#{@source_table}'
      );

      EXECUTE format(
        'CREATE UNIQUE INDEX IF NOT EXISTS %I ON %I.%I (bucket, severity_id)',
        'idx_ocsf_events_hourly_stats_bucket_severity',
        '#{prefix()}',
        '#{@view}'
      );

      EXECUTE format(
        'CREATE INDEX IF NOT EXISTS %I ON %I.%I (bucket DESC)',
        'idx_ocsf_events_hourly_stats_bucket',
        '#{prefix()}',
        '#{@view}'
      );

      SELECT EXISTS (
        SELECT 1
        FROM timescaledb_information.jobs
        WHERE proc_name = 'policy_refresh_continuous_aggregate'
          AND hypertable_schema = '#{prefix()}'
          AND hypertable_name = '#{@view}'
      ) INTO policy_exists;

      IF NOT policy_exists THEN
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
            RAISE NOTICE 'Could not add continuous aggregate policy to #{@view}: %', SQLERRM;
        END;
      END IF;

      BEGIN
        EXECUTE format(
          'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''#{@retention_interval}'', if_not_exists => true)',
          ts_schema,
          view_ident
        );
      EXCEPTION
        WHEN others THEN
          RAISE NOTICE 'Could not add retention policy to #{@view}: %', SQLERRM;
      END;

      BEGIN
        EXECUTE format(
          'CALL %I.refresh_continuous_aggregate(%L::regclass, NOW() - INTERVAL ''#{@retention_interval}'', NOW())',
          ts_schema,
          view_ident
        );
      EXCEPTION
        WHEN others THEN
          RAISE NOTICE 'Could not refresh continuous aggregate #{@view}: %', SQLERRM;
      END;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not create #{@view}: %', SQLERRM;
    END;
    $$;
    """)
  end

  def down do
    :ok
  end
end
