defmodule ServiceRadar.Repo.Migrations.RepairFlowTrafficRefreshPolicies do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # The original one-bucket windows were rejected by Timescale. Their errors
    # were swallowed, leaving WITH NO DATA views without a refresh policy.
    # Preserve operator policies; only install schedules that are missing.
    execute("""
    DO $$
    DECLARE
      ts_schema text;
      cfg record;
    BEGIN
      SELECT n.nspname INTO ts_schema
        FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
       WHERE e.extname = 'timescaledb';
      IF ts_schema IS NULL THEN RETURN; END IF;

      FOR cfg IN SELECT * FROM (VALUES
        ('flow_traffic_1h', '3 hours', '1 hour', '1 hour'),
        ('flow_traffic_1d', '3 days', '1 day', '1 day')
      ) AS policies(view_name, start_offset, end_offset, schedule_interval) LOOP
        IF EXISTS (
          SELECT 1 FROM _timescaledb_catalog.continuous_agg c
           WHERE c.user_view_schema = 'platform' AND c.user_view_name = cfg.view_name
             AND NOT EXISTS (
               SELECT 1 FROM timescaledb_information.jobs j
                WHERE j.proc_name = 'policy_refresh_continuous_aggregate'
                  AND (j.config->>'mat_hypertable_id')::integer = c.mat_hypertable_id
             )
        ) THEN
          EXECUTE format(
            'SELECT %I.add_continuous_aggregate_policy(%L::regclass, '
            'start_offset => %L::interval, end_offset => %L::interval, '
            'schedule_interval => %L::interval)',
            ts_schema, format('%I.%I', 'platform', cfg.view_name),
            cfg.start_offset, cfg.end_offset, cfg.schedule_interval
          );
        END IF;
      END LOOP;
    END;
    $$;
    """)

    flush()

    # Seed in dependency order from retained aggregates, never raw flows. Clip
    # to complete child coverage so shorter operator retention cannot erase old
    # parent history. A 29-day cap keeps deployment work bounded.
    refresh_from_retained_source(
      "flow_traffic_1h",
      "ocsf_network_activity_5m_traffic",
      "hour",
      "5 minutes"
    )

    refresh_from_retained_source("flow_traffic_1d", "flow_traffic_1h", "day", "1 hour")
  end

  defp refresh_from_retained_source(view, source, unit, source_width) do
    relations =
      repo().query!("SELECT to_regclass($1)::text, to_regclass($2)::text", [
        "platform." <> view,
        "platform." <> source
      ])

    case relations.rows do
      [[view_name, source_name]] when is_binary(view_name) and is_binary(source_name) ->
        %{rows: [[start_at, end_at]]} =
          repo().query!("""
          SELECT CASE WHEN min(bucket) IS NOT NULL THEN GREATEST(
                   date_trunc('day', now(), 'UTC') - INTERVAL '29 days',
                   CASE WHEN min(bucket) = date_trunc('#{unit}', min(bucket), 'UTC')
                     THEN min(bucket)
                     ELSE date_trunc('#{unit}', min(bucket), 'UTC') + INTERVAL '1 #{unit}'
                   END) END,
                 LEAST(date_trunc('#{unit}', now(), 'UTC'),
                   date_trunc('#{unit}', max(bucket) + INTERVAL '#{source_width}', 'UTC'))
            FROM platform.#{source}
          """)

        if start_at && DateTime.before?(start_at, end_at) do
          execute("""
          CALL refresh_continuous_aggregate('platform.#{view}',
            '#{DateTime.to_iso8601(start_at)}'::timestamptz,
            '#{DateTime.to_iso8601(end_at)}'::timestamptz)
          """)

          flush()
        end

      _ ->
        :ok
    end
  end

  # Keep repaired refresh schedules and populated history on application rollback.
  def down, do: :ok
end
