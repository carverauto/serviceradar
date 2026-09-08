defmodule ServiceRadar.Repo.Migrations.EnsureOcsfEventsHourlyStatsCagg do
  @moduledoc """
  Ensures the OCSF events hourly severity rollup exists outside a transaction.

  The original OCSF events CAGG migrations created the materialized view inside
  a migration transaction, which Timescale rejects on fresh databases. This
  safety-net migration creates the rollup in the same pattern used by the other
  post-February continuous aggregate ensure migrations.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @source_table "platform.ocsf_events"
  @view "platform.ocsf_events_hourly_stats"
  @retention_interval "24 hours"
  @refresh_start_offset "26 hours"
  @refresh_end_offset "5 minutes"
  @refresh_interval "5 minutes"

  def up do
    execute("""
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{@view}
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('1 hour', time) AS bucket,
      COALESCE(severity_id, 0) AS severity_id,
      COUNT(*)::bigint AS total_count
    FROM #{@source_table}
    GROUP BY 1, 2
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_events_hourly_stats_bucket_severity
    ON #{@view} (bucket, severity_id)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_events_hourly_stats_bucket
    ON #{@view} (bucket DESC)
    """)

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

      BEGIN
        EXECUTE format(
          'SELECT %I.add_continuous_aggregate_policy(%L::regclass, '
          'start_offset => INTERVAL ''#{@refresh_start_offset}'', '
          'end_offset => INTERVAL ''#{@refresh_end_offset}'', '
          'schedule_interval => INTERVAL ''#{@refresh_interval}'')',
          ts_schema,
          '#{@view}'
        );
      EXCEPTION
        WHEN others THEN
          NULL;
      END;

      BEGIN
        EXECUTE format(
          'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''#{@retention_interval}'', if_not_exists => true)',
          ts_schema,
          '#{@view}'
        );
      EXCEPTION
        WHEN others THEN
          NULL;
      END;

      BEGIN
        EXECUTE format(
          'CALL %I.refresh_continuous_aggregate(%L::regclass, NOW() - INTERVAL ''#{@retention_interval}'', NOW())',
          ts_schema,
          '#{@view}'
        );
      EXCEPTION
        WHEN others THEN
          NULL;
      END;
    END;
    $$;
    """)
  end

  def down do
    # No-op. We don't want to drop the rollup in a safety-net migration.
  end
end
