defmodule ServiceRadarWebNG.Jobs.ReapStalePeriodicJobsWorkerTest do
  use ServiceRadarWebNG.DataCase, async: false

  @moduletag :web_ng_shared_fixture_db

  import ExUnit.CaptureLog

  alias Oban.Job
  alias ServiceRadar.Jobs.ReapStalePeriodicJobsWorker
  alias ServiceRadar.Jobs.RefreshTraceSummariesWorker
  alias ServiceRadarWebNG.Plugins.FirstPartySyncWorker

  @repo ServiceRadar.Repo

  test "rescues stale cron jobs and emits operator-visible telemetry" do
    stale_job =
      insert_job!(
        RefreshTraceSummariesWorker,
        state: "executing",
        attempt: 1,
        max_attempts: 3,
        attempted_at: DateTime.shift(DateTime.utc_now(), day: -2),
        meta: %{"cron" => true}
      )

    handler_id = "periodic-cleanup-completed-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:serviceradar, :jobs, :periodic_cleanup, :completed],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      capture_log(fn ->
        assert :ok = ReapStalePeriodicJobsWorker.perform(%Job{args: %{}})
      end)

    rescued_job = @repo.get!(Job, stale_job.id)

    assert rescued_job.state == "available"
    assert log =~ "Reaped stale periodic Oban jobs"
    assert log =~ Integer.to_string(stale_job.id)
    assert log =~ inspect(RefreshTraceSummariesWorker)

    assert_receive {:telemetry, [:serviceradar, :jobs, :periodic_cleanup, :completed], measurements, metadata}

    assert measurements.rescued_count == 1
    assert measurements.discarded_count == 0

    assert [%{id: id, worker: worker}] = metadata.rescued_jobs
    assert id == stale_job.id
    assert worker == inspect(RefreshTraceSummariesWorker)
    assert metadata.discarded_jobs == []
  end

  test "discards stale cron jobs that exhausted all attempts" do
    # FirstPartySyncWorker is in sweep scope but implements no orphan rescue,
    # so the age-based sweep (not the rescue pass) owns this row.
    stale_job =
      insert_job!(
        FirstPartySyncWorker,
        state: "executing",
        attempt: 3,
        max_attempts: 3,
        attempted_at: DateTime.shift(DateTime.utc_now(), day: -2),
        meta: %{"cron" => true}
      )

    assert :ok = ReapStalePeriodicJobsWorker.perform(%Job{args: %{}})

    discarded_job = @repo.get!(Job, stale_job.id)

    assert discarded_job.state == "discarded"
    assert discarded_job.discarded_at
  end

  test "ignores stale non-periodic jobs" do
    # The reaper itself is neither orphan-rescuable nor in sweep scope, so a
    # row for it with no cron flag must survive the pass untouched.
    stale_job =
      insert_job!(
        ReapStalePeriodicJobsWorker,
        state: "executing",
        attempt: 1,
        max_attempts: 3,
        attempted_at: DateTime.shift(DateTime.utc_now(), day: -2),
        meta: %{}
      )

    log =
      capture_log(fn ->
        assert :ok = ReapStalePeriodicJobsWorker.perform(%Job{args: %{}})
      end)

    unchanged_job = @repo.get!(Job, stale_job.id)

    assert unchanged_job.state == "executing"
    refute log =~ "Reaped stale periodic Oban jobs"
  end

  defp insert_job!(worker, attrs) do
    now = DateTime.utc_now()
    attrs = Map.new(attrs)

    %{}
    |> Job.new(worker: worker, queue: :maintenance)
    |> Ecto.Changeset.change(
      state: Map.get(attrs, :state, "available"),
      attempt: Map.get(attrs, :attempt, 0),
      max_attempts: Map.get(attrs, :max_attempts, 20),
      attempted_at: Map.get(attrs, :attempted_at),
      meta: Map.get(attrs, :meta, %{}),
      inserted_at: Map.get(attrs, :inserted_at, now),
      scheduled_at: Map.get(attrs, :scheduled_at, now)
    )
    |> @repo.insert!()
  end
end
