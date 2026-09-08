defmodule ServiceRadar.Jobs.ScheduleHealthCheckTest do
  @moduledoc """
  Unit coverage for ng_job_schedules staleness detection (DIRE task 6.4).
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Jobs.ScheduleHealthCheck

  describe "interval_seconds/2" do
    test "infers interval from minute-step crons" do
      assert {:ok, 300} = ScheduleHealthCheck.interval_seconds("*/5 * * * *")
      assert {:ok, 60} = ScheduleHealthCheck.interval_seconds("* * * * *")
    end

    test "infers interval from hourly and daily crons" do
      assert {:ok, 3_600} = ScheduleHealthCheck.interval_seconds("0 * * * *")
      assert {:ok, 86_400} = ScheduleHealthCheck.interval_seconds("17 3 * * *")
    end

    test "rejects invalid crons" do
      assert {:error, _} = ScheduleHealthCheck.interval_seconds("not a cron")
      assert {:error, :no_cron} = ScheduleHealthCheck.interval_seconds(nil)
    end
  end

  describe "stale_schedules/2" do
    test "flags an enabled schedule whose last enqueue exceeds 2x its interval" do
      now = ~U[2026-06-10 12:00:00Z]

      # The production failure mode: 5-minute reconcile cron frozen for months.
      schedule =
        schedule_fixture(
          job_key: "device_identity_reconciliation",
          cron: "*/5 * * * *",
          last_enqueued_at: ~U[2026-02-06 15:25:06Z]
        )

      assert [entry] = ScheduleHealthCheck.stale_schedules([schedule], now)
      assert entry.job_key == "device_identity_reconciliation"
      assert entry.interval_seconds == 300
      assert entry.threshold_seconds == 600
      assert entry.seconds_since_enqueue > 86_400 * 100
    end

    test "does not flag a schedule enqueued within its threshold" do
      now = ~U[2026-06-10 12:00:00Z]

      schedule =
        schedule_fixture(
          cron: "*/5 * * * *",
          last_enqueued_at: ~U[2026-06-10 11:55:00Z]
        )

      assert [] = ScheduleHealthCheck.stale_schedules([schedule], now)
    end

    test "applies the 10-minute floor to high-frequency crons" do
      now = ~U[2026-06-10 12:00:00Z]

      # 1-minute cron, 8 minutes since last enqueue: past 2x interval but
      # under the floor — not stale (avoids flapping on scheduler jitter).
      schedule =
        schedule_fixture(
          cron: "* * * * *",
          last_enqueued_at: ~U[2026-06-10 11:52:00Z]
        )

      assert [] = ScheduleHealthCheck.stale_schedules([schedule], now)

      # 11 minutes: past the floor — stale.
      late = schedule_fixture(cron: "* * * * *", last_enqueued_at: ~U[2026-06-10 11:49:00Z])
      assert [_] = ScheduleHealthCheck.stale_schedules([late], now)
    end

    test "ignores disabled schedules" do
      now = ~U[2026-06-10 12:00:00Z]

      schedule =
        schedule_fixture(
          cron: "*/5 * * * *",
          enabled: false,
          last_enqueued_at: ~U[2026-02-06 15:25:06Z]
        )

      assert [] = ScheduleHealthCheck.stale_schedules([schedule], now)
    end

    test "falls back to inserted_at when never enqueued" do
      now = ~U[2026-06-10 12:00:00Z]

      stale_never_run =
        schedule_fixture(
          cron: "*/5 * * * *",
          last_enqueued_at: nil,
          inserted_at: ~U[2026-06-01 00:00:00Z]
        )

      assert [entry] = ScheduleHealthCheck.stale_schedules([stale_never_run], now)
      assert entry.last_enqueued_at == nil

      fresh_never_run =
        schedule_fixture(
          cron: "*/5 * * * *",
          last_enqueued_at: nil,
          inserted_at: ~U[2026-06-10 11:58:00Z]
        )

      assert [] = ScheduleHealthCheck.stale_schedules([fresh_never_run], now)
    end

    test "skips schedules it cannot evaluate" do
      now = ~U[2026-06-10 12:00:00Z]

      bad_cron = schedule_fixture(cron: "garbage", last_enqueued_at: ~U[2026-01-01 00:00:00Z])

      no_reference =
        schedule_fixture(cron: "*/5 * * * *", last_enqueued_at: nil, inserted_at: nil)

      assert [] = ScheduleHealthCheck.stale_schedules([bad_cron, no_reference], now)
      assert {:skip, _} = ScheduleHealthCheck.check_schedule(bad_cron, now)

      assert {:skip, :no_reference_timestamp} =
               ScheduleHealthCheck.check_schedule(no_reference, now)
    end
  end

  defp schedule_fixture(overrides) do
    Map.merge(
      %{
        job_key: "test_job",
        cron: "*/5 * * * *",
        timezone: "Etc/UTC",
        enabled: true,
        last_enqueued_at: nil,
        inserted_at: ~U[2026-01-01 00:00:00Z]
      },
      Map.new(overrides)
    )
  end
end
