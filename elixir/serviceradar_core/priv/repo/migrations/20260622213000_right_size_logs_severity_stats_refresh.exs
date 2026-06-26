defmodule ServiceRadar.Repo.Migrations.RightSizeLogsSeverityStatsRefresh do
  @moduledoc """
  Right-sizes the `logs_severity_stats_5m` continuous-aggregate refresh policy.

  `logs_severity_stats_5m` is refreshed by TWO mechanisms:
    1. a TimescaleDB refresh policy that ran every 2 minutes over a 3-hour
       window (`start_offset 3h`, `end_offset 1min`), and
    2. the `RefreshLogsSeverityStatsWorker` Oban job (`*/2` cron) which already
       refreshes `NOW() - 30 minutes .. NOW()`.

  The two overlap on the recent window, and the policy's 2-minute cadence was a
  large recurring CNPG cost (materialization inserts firing ~4.5/s in the live
  profile). This migration hands the recent 30-minute window to the Oban worker
  and relaxes the policy to a 10-minute cadence with a `30 minute` end-offset
  (still a 3-hour backfill depth for late-arriving logs).

  Defensive: `logs_severity_stats_5m` is not created by any migration on this
  branch (it exists out-of-band where deployed), so the policy changes are
  wrapped in a DO-block that resolves the TimescaleDB schema and swallows errors,
  matching `20260315120000_ensure_ocsf_events_hourly_stats_cagg.exs`.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @view "platform.logs_severity_stats_5m"

  def up do
    # serviceradar:allow-startup-maintenance - this only re-registers the
    # Timescale continuous-aggregate refresh policy; it does not refresh or
    # backfill the materialized view on first boot.
    reconfigure_policy(
      start_offset: "3 hours",
      end_offset: "30 minutes",
      schedule_interval: "10 minutes"
    )
  end

  def down do
    reconfigure_policy(
      start_offset: "3 hours",
      end_offset: "1 minute",
      schedule_interval: "2 minutes"
    )
  end

  defp reconfigure_policy(opts) do
    start_offset = Keyword.fetch!(opts, :start_offset)
    end_offset = Keyword.fetch!(opts, :end_offset)
    schedule_interval = Keyword.fetch!(opts, :schedule_interval)

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

      IF to_regclass('#{@view}') IS NULL THEN
        RETURN;
      END IF;

      BEGIN
        EXECUTE format(
          'SELECT %I.remove_continuous_aggregate_policy(%L::regclass, if_exists => true)',
          ts_schema,
          '#{@view}'
        );
      EXCEPTION
        WHEN others THEN
          NULL;
      END;

      BEGIN
        EXECUTE format(
          'SELECT %I.add_continuous_aggregate_policy(%L::regclass, '
          'start_offset => INTERVAL ''#{start_offset}'', '
          'end_offset => INTERVAL ''#{end_offset}'', '
          'schedule_interval => INTERVAL ''#{schedule_interval}'', '
          'if_not_exists => true)',
          ts_schema,
          '#{@view}'
        );
      EXCEPTION
        WHEN others THEN
          NULL;
      END;
    END
    $$;
    """)
  end
end
