defmodule ServiceRadar.Repo.Migrations.RepairCaggRefreshWindows do
  @moduledoc """
  Reapplies the safe continuous-aggregate refresh windows introduced by
  `20260716210000_clamp_cagg_refresh_windows`.

  A new migration version is required because changing the July migration
  cannot repair a deployment that has already recorded that version. Refresh
  windows that reach beyond their raw source's retention can recompute dropped
  regions from empty raw data and delete previously materialized history.

  This repair only re-registers policies for continuous aggregates that are
  present. It does not refresh or backfill a materialized view.
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
    # serviceradar:allow-startup-maintenance - this bounded repair only
    # re-registers nine Timescale continuous-aggregate policy catalog rows. It
    # does not refresh or backfill materialized data, and every absent
    # extension, relation, or CAGG is an explicit no-op.
    Enum.each(@clamps, fn {view, start_offset, end_offset, schedule_interval} ->
      execute(reset_policy_sql(view, start_offset, end_offset, schedule_interval))
    end)
  end

  # Restoring the old refresh windows would reintroduce the materialized-history
  # deletion hazard. Rolling back the schema version must leave the safe policy
  # configuration in place.
  def down, do: :ok

  defp reset_policy_sql(view, start_offset, end_offset, schedule_interval) do
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

      IF ts_schema IS NULL THEN
        RETURN;
      END IF;

      IF to_regclass('timescaledb_information.continuous_aggregates') IS NULL
         OR to_regclass('platform.#{view}') IS NULL THEN
        RETURN;
      END IF;

      IF NOT EXISTS (
        SELECT 1
        FROM timescaledb_information.continuous_aggregates
        WHERE view_schema = 'platform'
          AND view_name = '#{view}'
      ) THEN
        RETURN;
      END IF;

      EXECUTE format(
        'SELECT %I.remove_continuous_aggregate_policy(%L::regclass, if_exists => true)',
        ts_schema,
        'platform.#{view}'
      );

      EXECUTE format(
        'SELECT %I.add_continuous_aggregate_policy(%L::regclass, '
        || 'start_offset => INTERVAL ''#{start_offset}'', '
        || 'end_offset => INTERVAL ''#{end_offset}'', '
        || 'schedule_interval => INTERVAL ''#{schedule_interval}'', '
        || 'if_not_exists => true)',
        ts_schema,
        'platform.#{view}'
      );
    END;
    $$;
    """
  end
end
