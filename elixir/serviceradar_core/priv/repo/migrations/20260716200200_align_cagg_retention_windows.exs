defmodule ServiceRadar.Repo.Migrations.AlignCaggRetentionWindows do
  @moduledoc """
  Align under-retained continuous-aggregate windows with their surfaces'
  lookback ambitions (OpenSpec add-tiered-telemetry-offload, task 2.8).

  Raw-granularity history beyond the hot window is served by the cold tier;
  stats/downsample queries stay on in-database CAGGs — but several CAGGs
  retain less than the surfaces built on them can usefully look back:

    * ocsf_events_hourly_stats: 24 hours -> 90 days
    * traces_stats_5m: 14 days -> 90 days (matches spans_red_1h)
    * ocsf_network_activity_hourly_{proto,talkers,ports}: 30 -> 90 days
      (matches listeners/conversations; 5m traffic stays at 30 days by
      design — long-window flow stats ride the 1h/1d hierarchical CAGGs)

  Rollups are small relative to raw hypertables; this is the deliberately
  boring alternative to exporting CAGGs to the cold tier (deferred until a
  window beyond 395 days is required).
  """

  use Ecto.Migration

  @windows [
    {"ocsf_events_hourly_stats", 90},
    {"traces_stats_5m", 90},
    {"ocsf_network_activity_hourly_proto", 90},
    {"ocsf_network_activity_hourly_talkers", 90},
    {"ocsf_network_activity_hourly_ports", 90}
  ]

  def up do
    for {cagg, days} <- @windows do
      execute """
      DO $$
      DECLARE
        ts_schema text;
      BEGIN
        SELECT n.nspname
        INTO ts_schema
        FROM pg_extension e
        JOIN pg_namespace n ON n.oid = e.extnamespace
        WHERE e.extname = 'timescaledb';

        IF ts_schema IS NOT NULL
           AND EXISTS (
             SELECT 1
             FROM timescaledb_information.continuous_aggregates
             WHERE view_schema = 'platform'
               AND view_name = '#{cagg}'
           ) THEN
          EXECUTE format(
            'SELECT %I.remove_retention_policy(%L::regclass, if_exists => true)',
            ts_schema,
            'platform.#{cagg}'
          );

          EXECUTE format(
            'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''#{days} days'', if_not_exists => true)',
            ts_schema,
            'platform.#{cagg}'
          );
        END IF;
      EXCEPTION
        WHEN others THEN
          RAISE NOTICE 'Could not align retention for #{cagg}: %', SQLERRM;
      END;
      $$;
      """
    end
  end

  def down do
    # Restore the previous windows.
    for {cagg, days} <- [
          {"ocsf_events_hourly_stats", 1},
          {"traces_stats_5m", 14},
          {"ocsf_network_activity_hourly_proto", 30},
          {"ocsf_network_activity_hourly_talkers", 30},
          {"ocsf_network_activity_hourly_ports", 30}
        ] do
      execute """
      DO $$
      DECLARE
        ts_schema text;
      BEGIN
        SELECT n.nspname
        INTO ts_schema
        FROM pg_extension e
        JOIN pg_namespace n ON n.oid = e.extnamespace
        WHERE e.extname = 'timescaledb';

        IF ts_schema IS NOT NULL
           AND EXISTS (
             SELECT 1
             FROM timescaledb_information.continuous_aggregates
             WHERE view_schema = 'platform'
               AND view_name = '#{cagg}'
           ) THEN
          EXECUTE format(
            'SELECT %I.remove_retention_policy(%L::regclass, if_exists => true)',
            ts_schema,
            'platform.#{cagg}'
          );

          EXECUTE format(
            'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''#{days} days'', if_not_exists => true)',
            ts_schema,
            'platform.#{cagg}'
          );
        END IF;
      EXCEPTION
        WHEN others THEN
          RAISE NOTICE 'Could not restore retention for #{cagg}: %', SQLERRM;
      END;
      $$;
      """
    end
  end
end
