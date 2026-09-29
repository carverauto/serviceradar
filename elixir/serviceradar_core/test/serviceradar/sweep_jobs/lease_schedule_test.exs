defmodule ServiceRadar.SweepJobs.LeaseScheduleTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SweepJobs.LeaseSchedule

  describe "parse/1" do
    for {text, seconds} <- [
          {"15m", 900},
          {"1h", 3600},
          {"1h30m", 5400},
          {"1.5h", 5400},
          {"2d", 172_800},
          {"300s", 300},
          {" 10m ", 600}
        ] do
      test "#{inspect(text)} is #{seconds} seconds" do
        assert {:ok, {:interval, unquote(seconds)}} =
                 LeaseSchedule.parse(%{schedule_type: :interval, interval: unquote(text)})
      end
    end

    for {text, reason} <- [
          {"4m", :interval_too_short},
          {"60s", :interval_too_short},
          {"", :invalid_interval},
          {"soon", :invalid_interval},
          {"15", :invalid_interval},
          {"15m and", :invalid_interval}
        ] do
      test "#{inspect(text)} is refused as #{reason}" do
        assert {:error, unquote(reason)} =
                 LeaseSchedule.parse(%{schedule_type: :interval, interval: unquote(text)})
      end
    end

    test "a cron group carries its expression, and a bad one is refused" do
      assert {:ok, {:cron, _}} =
               LeaseSchedule.parse(%{schedule_type: :cron, cron_expression: "*/15 * * * *"})

      assert {:error, :invalid_cron} =
               LeaseSchedule.parse(%{schedule_type: :cron, cron_expression: "not a cron"})

      assert {:error, :invalid_cron} =
               LeaseSchedule.parse(%{schedule_type: :cron, cron_expression: nil})
    end
  end

  describe "slots/3 for an interval" do
    test "start on multiples of the interval and each ends where the next starts" do
      spec = {:interval, 900}

      assert [first, second, third] =
               LeaseSchedule.slots(spec, ~U[2026-10-01 12:03:00Z], ~U[2026-10-01 13:00:00Z])

      assert first.start == ~U[2026-10-01 12:15:00Z]
      assert first.expires == second.start
      assert second.start == ~U[2026-10-01 12:30:00Z]
      assert third.start == ~U[2026-10-01 12:45:00Z]
      assert third.expires == ~U[2026-10-01 13:00:00Z]
    end

    test "a slot that starts exactly at `from` is included and one at `until` is not" do
      assert [%{start: ~U[2026-10-01 12:00:00Z]}, %{start: ~U[2026-10-01 12:15:00Z]}] =
               LeaseSchedule.slots(
                 {:interval, 900},
                 ~U[2026-10-01 12:00:00Z],
                 ~U[2026-10-01 12:30:00Z]
               )
    end

    test "a slot never starts before `from`, even by a fraction of a second" do
      assert [%{start: ~U[2026-10-01 12:15:00Z]} | _] =
               LeaseSchedule.slots(
                 {:interval, 900},
                 ~U[2026-10-01 12:00:00.500Z],
                 ~U[2026-10-01 12:40:00Z]
               )
    end

    test "a slot that starts before a fractional `until` is included" do
      assert [%{start: ~U[2026-10-01 12:15:00Z]}] =
               LeaseSchedule.slots(
                 {:interval, 900},
                 ~U[2026-10-01 12:00:00.500Z],
                 ~U[2026-10-01 12:15:00.500Z]
               )
    end

    test "a slot that starts exactly at a whole-second `until` is excluded" do
      assert [] =
               LeaseSchedule.slots(
                 {:interval, 900},
                 ~U[2026-10-01 12:00:00.500Z],
                 ~U[2026-10-01 12:15:00Z]
               )
    end

    test "overlapping stretches of time agree on where the slots are" do
      spec = {:interval, 600}
      earlier = LeaseSchedule.slots(spec, ~U[2026-10-01 12:00:00Z], ~U[2026-10-01 14:00:00Z])
      later = LeaseSchedule.slots(spec, ~U[2026-10-01 13:00:00Z], ~U[2026-10-01 15:00:00Z])

      shared = Enum.filter(earlier, &(&1 in later))

      assert length(shared) == 6
      assert Enum.all?(shared, &(DateTime.compare(&1.start, ~U[2026-10-01 13:00:00Z]) != :lt))
    end

    test "a stretch shorter than the interval can hold no slot" do
      assert [] =
               LeaseSchedule.slots(
                 {:interval, 3600},
                 ~U[2026-10-01 12:01:00Z],
                 ~U[2026-10-01 12:30:00Z]
               )
    end
  end

  describe "slots/3 for cron" do
    test "one slot per fire, each ending at the next" do
      {:ok, spec} = LeaseSchedule.parse(%{schedule_type: :cron, cron_expression: "*/15 * * * *"})

      assert [a, b, c, d] =
               LeaseSchedule.slots(spec, ~U[2026-10-01 12:00:00Z], ~U[2026-10-01 13:00:00Z])

      assert Enum.map([a, b, c, d], & &1.start) == [
               ~U[2026-10-01 12:00:00Z],
               ~U[2026-10-01 12:15:00Z],
               ~U[2026-10-01 12:30:00Z],
               ~U[2026-10-01 12:45:00Z]
             ]

      assert a.expires == b.start
      assert d.expires == ~U[2026-10-01 13:00:00Z]
    end

    test "a minute cron over three days returns 4320 slots" do
      {:ok, spec} = LeaseSchedule.parse(%{schedule_type: :cron, cron_expression: "* * * * *"})

      slots = LeaseSchedule.slots(spec, ~U[2026-10-01 00:00:00Z], ~U[2026-10-04 00:00:00Z])

      assert [first | _] = slots
      assert length(slots) == 4_320
      assert first.start == ~U[2026-10-01 00:00:00Z]
      assert first.expires == ~U[2026-10-01 00:01:00Z]

      assert %{start: ~U[2026-10-03 23:59:00Z], expires: ~U[2026-10-04 00:00:00Z]} =
               Enum.at(slots, -1)
    end

    test "a daily cron gives one slot a day" do
      {:ok, spec} = LeaseSchedule.parse(%{schedule_type: :cron, cron_expression: "30 2 * * *"})

      slots = LeaseSchedule.slots(spec, ~U[2026-10-01 00:00:00Z], ~U[2026-10-04 00:00:00Z])

      assert Enum.map(slots, & &1.start) == [
               ~U[2026-10-01 02:30:00Z],
               ~U[2026-10-02 02:30:00Z],
               ~U[2026-10-03 02:30:00Z]
             ]
    end
  end
end
