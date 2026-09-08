defmodule ServiceRadar.Repo.Migrations.RepairOcsfEventsHourlyStatsCagg do
  @moduledoc """
  Replaces a leftover `ocsf_events_hourly_stats` view with a real CAGG.

  The consolidated baseline dumped the CAGG as an ordinary view over an empty
  `_materialized_hypertable_*`. `to_regclass` then succeeds, dashboard queries
  return zero closed-hour buckets, and Timescale never refreshes the rollup.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @source_table "platform.ocsf_events"
  @view "platform.ocsf_events_hourly_stats"
  @candidate_view "platform.ocsf_events_hourly_stats_v2"
  @stale_view "platform.ocsf_events_hourly_stats_stale_view"
  @refresh_start_offset "26 hours"
  @refresh_end_offset "5 minutes"
  @refresh_interval "5 minutes"

  def up do
    # serviceradar:allow-startup-maintenance - WITH NO DATA makes creation
    # metadata-only. Policy refresh later fills closed hours. The dashboard
    # falls back to raw ocsf_events until that first refresh lands.
    if promotion_already_complete?() do
      configure_promoted_policy()
    else
      preflight_promotion()
      create_candidate()
      configure_candidate_policy()
      promote_candidate()
    end
  end

  def down do
    # Safety-net migration: never remove a rollup that may predate this version.
  end

  defp promotion_already_complete? do
    %{rows: [[complete]]} =
      repo().query!(
        """
        SELECT
          to_regclass($1) IS NOT NULL
          AND to_regclass($2) IS NULL
          AND EXISTS (
            SELECT 1
            FROM timescaledb_information.continuous_aggregates
            WHERE view_schema = 'platform'
              AND view_name = 'ocsf_events_hourly_stats'
          )
        """,
        [@view, @candidate_view]
      )

    complete == true
  end

  defp preflight_promotion do
    execute("""
    DO $$
    BEGIN
      IF to_regclass('#{@stale_view}') IS NOT NULL
         AND to_regclass('#{@view}') IS NOT NULL THEN
        RAISE EXCEPTION '#{@stale_view} already exists; refusing an ambiguous CAGG promotion';
      END IF;
    END;
    $$;
    """)
  end

  defp create_candidate do
    execute("""
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{@candidate_view}
    WITH (
      timescaledb.continuous,
      timescaledb.create_group_indexes = false
    ) AS
    SELECT
      time_bucket('1 hour', time) AS bucket,
      COALESCE(severity_id, 0) AS severity_id,
      COUNT(*)::bigint AS total_count
    FROM #{@source_table}
    GROUP BY 1, 2
    WITH NO DATA
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_events_hourly_stats_v2_bucket_severity
    ON #{@candidate_view} (bucket, severity_id)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_events_hourly_stats_v2_bucket
    ON #{@candidate_view} (bucket DESC)
    """)
  end

  defp configure_candidate_policy do
    configure_policy(@candidate_view)
  end

  defp configure_promoted_policy do
    configure_policy(@view)
  end

  defp configure_policy(view) do
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
        RAISE EXCEPTION 'TimescaleDB extension is required for #{view}';
      END IF;

      IF to_regclass('#{view}') IS NULL THEN
        RAISE EXCEPTION 'CAGG #{view} is missing';
      END IF;

      EXECUTE format(
        'SELECT %I.add_continuous_aggregate_policy(%L::regclass, '
        'start_offset => INTERVAL ''#{@refresh_start_offset}'', '
        'end_offset => INTERVAL ''#{@refresh_end_offset}'', '
        'schedule_interval => INTERVAL ''#{@refresh_interval}'', '
        'if_not_exists => true)',
        ts_schema,
        '#{view}'
      );
    END;
    $$;
    """)
  end

  defp promote_candidate do
    execute("""
    DO $$
    DECLARE
      current_kind "char";
    BEGIN
      SELECT c.relkind
      INTO current_kind
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'platform'
        AND c.relname = 'ocsf_events_hourly_stats';

      IF current_kind = 'v' THEN
        ALTER VIEW #{@view} RENAME TO ocsf_events_hourly_stats_stale_view;
      ELSIF current_kind = 'm' THEN
        ALTER MATERIALIZED VIEW #{@view} RENAME TO ocsf_events_hourly_stats_stale_view;
      END IF;

      ALTER MATERIALIZED VIEW #{@candidate_view}
        RENAME TO ocsf_events_hourly_stats;
    END;
    $$;
    """)
  end
end
