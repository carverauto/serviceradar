defmodule ServiceRadar.Repo.Migrations.AddOcsfEventsHourlyStats do
  @moduledoc """
  Creates a TimescaleDB continuous aggregate for OCSF event severity counts.

  This migration is idempotent and safe to re-run.
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
    BEGIN
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NOT NULL THEN
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
      ELSE
        RAISE NOTICE 'TimescaleDB extension not available, skipping #{@view}';
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not create #{@view}: %', SQLERRM;
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
      view_ident := format('%I.%I', '#{prefix()}', '#{@view}');

      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NOT NULL THEN
        BEGIN
          EXECUTE format(
            'SELECT %I.remove_retention_policy(%L::regclass, if_exists => true)',
            ts_schema,
            view_ident
          );
        EXCEPTION
          WHEN others THEN
            RAISE NOTICE 'Could not remove retention policy from #{@view}: %', SQLERRM;
        END;

        BEGIN
          EXECUTE format(
            'SELECT %I.remove_continuous_aggregate_policy(%L::regclass)',
            ts_schema,
            view_ident
          );
        EXCEPTION
          WHEN others THEN
            RAISE NOTICE 'Could not remove continuous aggregate policy from #{@view}: %', SQLERRM;
        END;
      END IF;

      EXECUTE format('DROP MATERIALIZED VIEW IF EXISTS %I.%I', '#{prefix()}', '#{@view}');
      EXECUTE format(
        'DROP INDEX IF EXISTS %I.%I',
        '#{prefix()}',
        'idx_ocsf_events_hourly_stats_bucket_severity'
      );
      EXECUTE format(
        'DROP INDEX IF EXISTS %I.%I',
        '#{prefix()}',
        'idx_ocsf_events_hourly_stats_bucket'
      );
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not drop #{@view}: %', SQLERRM;
    END;
    $$;
    """)
  end
end
