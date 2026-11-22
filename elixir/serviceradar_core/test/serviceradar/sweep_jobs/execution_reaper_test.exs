defmodule ServiceRadar.SweepJobs.ExecutionReaperTest do
  @moduledoc """
  Unit tests for ExecutionReaper abandonment rules, including expired leased
  sweep execution slots.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.SweepJobs.ExecutionReaper

  @bounds %{
    disabled_grace: 600,
    lease_grace: 60,
    min_stale: 1_800,
    max_stale: 21_600
  }

  test "reaps a leased execution once its collection window expired and progress stopped" do
    now = ~U[2026-11-22 08:05:00Z]

    candidate = %{
      updated_at: ~U[2026-11-22 08:01:06Z],
      group_enabled: true,
      interval: "5m",
      schedule_type: :interval,
      collection_expires: ~U[2026-11-22 08:00:00Z]
    }

    assert ExecutionReaper.abandon_reason(candidate, now, @bounds) ==
             "incomplete: leased collection window expired at 2026-11-22T08:00:00Z"
  end

  test "does not reap an expired leased execution while spooled chunks are still arriving" do
    now = ~U[2026-11-22 08:01:30Z]

    candidate = %{
      updated_at: ~U[2026-11-22 08:01:00Z],
      group_enabled: true,
      interval: "5m",
      schedule_type: :interval,
      collection_expires: ~U[2026-11-22 08:00:00Z]
    }

    assert ExecutionReaper.abandon_reason(candidate, now, @bounds) == nil
  end

  test "does not reap a leased execution before its collection window plus grace expires" do
    now = ~U[2026-11-22 08:00:30Z]

    candidate = %{
      updated_at: ~U[2026-11-22 07:58:00Z],
      group_enabled: true,
      interval: "5m",
      schedule_type: :interval,
      collection_expires: ~U[2026-11-22 08:00:00Z]
    }

    assert ExecutionReaper.abandon_reason(candidate, now, @bounds) == nil
  end

  test "keeps existing stale bound for non-leased executions without collection_expires" do
    now = ~U[2026-11-22 08:05:00Z]

    candidate = %{
      updated_at: ~U[2026-11-22 08:00:00Z],
      group_enabled: true,
      interval: "5m",
      schedule_type: :interval,
      collection_expires: nil
    }

    assert ExecutionReaper.abandon_reason(candidate, now, @bounds) == nil
  end
end
