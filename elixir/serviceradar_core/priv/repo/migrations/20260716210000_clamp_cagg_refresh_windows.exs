defmodule ServiceRadar.Repo.Migrations.ClampCaggRefreshWindows do
  @moduledoc """
  Clamp continuous-aggregate refresh windows to their raw source's retention
  (OpenSpec add-tiered-telemetry-offload; verified on TimescaleDB 2.24.0).

  `drop_chunks` writes invalidation-log entries covering every dropped chunk.
  Any refresh whose window covers such a region recomputes those buckets from
  now-empty raw and DELETES the materialized history — verified empirically:
  the production-shaped policy (start_offset '32 days' over 7-day-retained
  raw) wiped all pre-retention buckets in a single policy run.

  Several CAGGs refresh further back than their raw source retains, which
  means their long-retention materializations are progressively destroyed as
  raw ages out:

    * cpu/memory/disk/process/timeseries_metrics_hourly + interface hourly:
      start_offset 32d over 7d raw  -> clamp to 5d
    * spans_red_1h: 32d over 3d raw (otel_traces)        -> clamp to 1d
    * traces_stats_5m: 7d over 3d raw (otel_traces)      -> clamp to 1d
    * otel_metrics_hourly_stats: 32d over 30d raw        -> clamp to 28d

  The clamp preserves each policy's end_offset/schedule. Already-wiped
  buckets are not resurrected by this migration (raw is gone); on
  cold-configured deployments they become repairable from the Parquet tier
  (documented follow-up).
  """

  use Ecto.Migration

  # {view, start_offset, end_offset, schedule_interval}
  @clamps [
    {"cpu_metrics_hourly", "5 days", "10 minutes", "10 minutes"},
    {"memory_metrics_hourly", "5 days", "10 minutes", "10 minutes"},
    {"disk_metrics_hourly", "5 days", "10 minutes", "10 minutes"},
    {"process_metrics_hourly", "5 days", "10 minutes", "10 minutes"},
    {"timeseries_metrics_hourly", "5 days", "10 minutes", "10 minutes"},
    {"timeseries_metrics_interface_hourly", "5 days", "10 minutes", "10 minutes"},
    {"spans_red_1h", "1 day", "10 minutes", "10 minutes"},
    {"traces_stats_5m", "1 day", "5 minutes", "5 minutes"},
    {"otel_metrics_hourly_stats", "28 days", "10 minutes", "10 minutes"}
  ]

  def up do
    # serviceradar:allow-startup-maintenance - this only re-registers Timescale
    # continuous-aggregate refresh POLICIES; it does not refresh or backfill any
    # materialized view. add_continuous_aggregate_policy writes a background-job
    # catalog row and returns -- the refresh happens later on the job's own
    # schedule. Bounded at eleven views, and a no-op on first boot, where the
    # EXISTS guard finds no continuous aggregates to clamp.
    for {view, start_offset, end_offset, schedule} <- @clamps do
      execute(reset_policy_sql(view, start_offset, end_offset, schedule))
    end
  end

  def down do
    # Restore the previous (hazardous) offsets.
    for {view, start_offset, end_offset, schedule} <- [
          {"cpu_metrics_hourly", "32 days", "10 minutes", "10 minutes"},
          {"memory_metrics_hourly", "32 days", "10 minutes", "10 minutes"},
          {"disk_metrics_hourly", "32 days", "10 minutes", "10 minutes"},
          {"process_metrics_hourly", "32 days", "10 minutes", "10 minutes"},
          {"timeseries_metrics_hourly", "32 days", "10 minutes", "10 minutes"},
          {"timeseries_metrics_interface_hourly", "32 days", "10 minutes", "10 minutes"},
          {"spans_red_1h", "32 days", "10 minutes", "10 minutes"},
          {"traces_stats_5m", "7 days", "5 minutes", "5 minutes"},
          {"otel_metrics_hourly_stats", "32 days", "10 minutes", "10 minutes"}
        ] do
      execute(reset_policy_sql(view, start_offset, end_offset, schedule))
    end
  end

  defp reset_policy_sql(view, start_offset, end_offset, schedule) do
    """
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
             AND view_name = '#{view}'
         ) THEN
        EXECUTE format(
          'SELECT %I.remove_continuous_aggregate_policy(%L::regclass, if_exists => true)',
          ts_schema,
          'platform.#{view}'
        );

        EXECUTE format(
          'SELECT %I.add_continuous_aggregate_policy(%L::regclass, '
          || 'start_offset => INTERVAL ''#{start_offset}'', '
          || 'end_offset => INTERVAL ''#{end_offset}'', '
          || 'schedule_interval => INTERVAL ''#{schedule}'', '
          || 'if_not_exists => true)',
          ts_schema,
          'platform.#{view}'
        );
      END IF;
    END;
    $$;
    """
  end
end
