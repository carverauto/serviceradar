defmodule ServiceRadarWebNG.JobsTest do
  use ServiceRadarWebNG.DataCase, async: true

  alias ServiceRadarWebNG.Jobs
  alias ServiceRadarWebNG.Jobs.Schedule
  alias ServiceRadarWebNG.Jobs.RefreshTraceSummariesWorker
  alias ServiceRadarWebNG.Repo

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

    test "lists recent runs for a scheduled job" do
      {:ok, job} =
        RefreshTraceSummariesWorker.new(%{}, queue: :maintenance)
        |> Repo.insert()

      runs = Jobs.list_recent_runs("refresh_trace_summaries", limit: 5)

      assert Enum.any?(runs, &(&1.id == job.id))
    end
  end
end
