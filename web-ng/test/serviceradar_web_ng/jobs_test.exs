defmodule ServiceRadarWebNG.JobsTest do
  use ServiceRadarWebNG.DataCase, async: true

  alias ServiceRadarWebNG.Jobs
  alias ServiceRadarWebNG.Jobs.Schedule

  describe "schedules" do
    test "validates cron expressions" do
      changeset = Schedule.changeset(%Schedule{}, %{cron: "not-a-cron", timezone: "Etc/UTC"})
      assert %{cron: errors} = errors_on(changeset)
      assert Enum.any?(errors, &String.contains?(&1, "invalid cron expression"))
    end

    test "calculates next run from last enqueued timestamp" do
      schedule = %Schedule{
        cron: "*/2 * * * *",
        timezone: "Etc/UTC",
        last_enqueued_at: ~U[2025-01-01 00:00:00Z]
      }

      assert Jobs.next_run_at(schedule, ~U[2025-01-01 00:01:30Z]) ==
               ~U[2025-01-01 00:02:00Z]
    end
  end
end
