defmodule ServiceRadar.SweepJobs.ExecutionReaperTest do
  @moduledoc """
  Unit tests for ExecutionReaper abandonment rules, including expired leased
  sweep execution slots.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.SweepJobs.ExecutionReaper
  alias ServiceRadar.SweepJobs.LeaseMisses

  @bounds %{
    disabled_grace: 600,
    min_stale: 1_800,
    max_stale: 21_600
  }

  test "defaults lease grace to LeaseMisses.grace_seconds/0 so late chunks stay running" do
    expires = ~U[2026-11-22 08:00:00Z]

    candidate = %{
      id: "00000000-0000-0000-0000-000000000001",
      updated_at: expires,
      group_enabled: true,
      interval: "5m",
      schedule_type: :interval,
      collection_expires: expires
    }

    two_minutes_late = ~U[2026-11-22 08:02:00Z]
    just_before_grace = DateTime.shift(expires, second: LeaseMisses.grace_seconds() - 1)
    at_grace = DateTime.shift(expires, second: LeaseMisses.grace_seconds())

    assert ExecutionReaper.abandon_reason(candidate, two_minutes_late, @bounds) == nil

    assert {:ok, %{failed: 0, skipped: 0, errors: 0}} =
             ExecutionReaper.reap(now: two_minutes_late, lister: fn _ -> {:ok, [candidate]} end)

    assert ExecutionReaper.abandon_reason(candidate, just_before_grace, @bounds) == nil

    assert {:ok, %{failed: 0, skipped: 0, errors: 0}} =
             ExecutionReaper.reap(now: just_before_grace, lister: fn _ -> {:ok, [candidate]} end)

    assert ExecutionReaper.abandon_reason(candidate, at_grace, @bounds) ==
             "incomplete: leased collection window expired at 2026-11-22T08:00:00Z"
  end

  test "reaps a leased execution once its collection window expired and progress stopped" do
    now = ~U[2026-11-22 08:06:00Z]

    candidate = %{
      updated_at: ~U[2026-11-22 08:00:30Z],
      group_enabled: true,
      interval: "5m",
      schedule_type: :interval,
      collection_expires: ~U[2026-11-22 08:00:00Z]
    }

    assert ExecutionReaper.abandon_reason(candidate, now, @bounds) ==
             "incomplete: leased collection window expired at 2026-11-22T08:00:00Z"
  end

  test "does not reap an expired leased execution while spooled chunks are still arriving" do
    now = ~U[2026-11-22 08:06:00Z]

    candidate = %{
      updated_at: ~U[2026-11-22 08:04:00Z],
      group_enabled: true,
      interval: "5m",
      schedule_type: :interval,
      collection_expires: ~U[2026-11-22 08:00:00Z]
    }

    assert ExecutionReaper.abandon_reason(candidate, now, @bounds) == nil
  end

  test "does not reap a leased execution before its collection window plus grace expires" do
    now = ~U[2026-11-22 08:04:30Z]

    candidate = %{
      updated_at: ~U[2026-11-22 07:58:00Z],
      group_enabled: true,
      interval: "5m",
      schedule_type: :interval,
      collection_expires: ~U[2026-11-22 08:00:00Z]
    }

    assert ExecutionReaper.abandon_reason(candidate, now, @bounds) == nil

    open_window_candidate = %{candidate | collection_expires: ~U[2026-11-22 08:10:00Z]}
    assert ExecutionReaper.abandon_reason(open_window_candidate, now, @bounds) == nil
  end

  test "respects an explicit lease_grace override" do
    now = ~U[2026-11-22 08:02:00Z]

    candidate = %{
      id: "00000000-0000-0000-0000-000000000002",
      updated_at: ~U[2026-11-22 08:01:00Z],
      group_enabled: true,
      interval: "5m",
      schedule_type: :interval,
      collection_expires: ~U[2026-11-22 08:00:00Z]
    }

    assert ExecutionReaper.abandon_reason(candidate, now, Map.put(@bounds, :lease_grace, 60)) ==
             "incomplete: leased collection window expired at 2026-11-22T08:00:00Z"

    # When lease_grace_seconds is raised above the elapsed 360s, reap/1 keeps the run alive.
    later = ~U[2026-11-22 08:06:00Z]
    quiet_candidate = %{candidate | updated_at: ~U[2026-11-22 08:00:00Z]}

    assert {:ok, %{failed: 0, skipped: 0, errors: 0}} =
             ExecutionReaper.reap(
               now: later,
               lease_grace_seconds: 600,
               lister: fn _ -> {:ok, [quiet_candidate]} end
             )
  end

  test "keeps existing stale and disabled bounds for non-leased executions" do
    now = ~U[2026-11-22 08:10:00Z]

    candidate = %{
      updated_at: ~U[2026-11-22 08:00:00Z],
      group_enabled: true,
      interval: "5m",
      schedule_type: :interval,
      collection_expires: nil
    }

    assert ExecutionReaper.abandon_reason(candidate, now, @bounds) == nil

    # Without collection_expires key at all, stale and disabled rules still apply cleanly.
    legacy_candidate = Map.delete(candidate, :collection_expires)
    assert ExecutionReaper.abandon_reason(legacy_candidate, now, @bounds) == nil

    assert ExecutionReaper.abandon_reason(legacy_candidate, ~U[2026-11-22 08:30:00Z], @bounds) ==
             "abandoned: no progress since 2026-11-22T08:00:00Z"

    disabled_candidate = %{legacy_candidate | group_enabled: false}

    assert ExecutionReaper.abandon_reason(disabled_candidate, now, @bounds) ==
             "abandoned: sweep group disabled"
  end
end
