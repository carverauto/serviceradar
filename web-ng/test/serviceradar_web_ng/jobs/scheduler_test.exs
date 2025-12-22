defmodule ServiceRadarWebNG.Jobs.SchedulerTest do
  use ServiceRadarWebNG.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias ServiceRadarWebNG.Jobs
  alias ServiceRadarWebNG.Jobs.Schedule
  alias ServiceRadarWebNG.Repo

  test "enqueues due schedules and updates last_enqueued_at" do
    schedule =
      Schedule
      |> Repo.get_by!(job_key: "refresh_trace_summaries")
      |> Ecto.Changeset.change(cron: "* * * * *", last_enqueued_at: nil, unique_period_seconds: 1)
      |> Repo.update!()

    result = Jobs.enqueue_due_schedules()
    assert result.enqueued >= 1

    job =
      from(j in Oban.Job, where: j.worker == "ServiceRadarWebNG.Jobs.RefreshTraceSummariesWorker")
      |> Repo.one()

    assert job

    schedule = Repo.get!(Schedule, schedule.id)
    assert schedule.last_enqueued_at
  end

  test "applies cron override when configured" do
    schedule = Repo.get_by!(Schedule, job_key: "refresh_trace_summaries")
    original_cron = schedule.cron

    System.put_env("TRACE_SUMMARIES_REFRESH_CRON", "*/5 * * * *")

    on_exit(fn ->
      System.delete_env("TRACE_SUMMARIES_REFRESH_CRON")
    end)

    assert :ok = Jobs.apply_env_overrides()

    schedule = Repo.get!(Schedule, schedule.id)
    assert schedule.cron == "*/5 * * * *"

    schedule
    |> Ecto.Changeset.change(cron: original_cron)
    |> Repo.update!()
  end
end
