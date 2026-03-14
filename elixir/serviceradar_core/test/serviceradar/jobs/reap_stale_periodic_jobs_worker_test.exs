defmodule ServiceRadar.Jobs.ReapStalePeriodicJobsWorkerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Jobs.ReapStalePeriodicJobsWorker
  alias ServiceRadar.Jobs.RefreshTraceSummariesWorker

  describe "split_stale_jobs/1" do
    test "rescues retryable jobs and discards exhausted jobs" do
      retryable = %{
        id: 101,
        worker: inspect(RefreshTraceSummariesWorker),
        queue: "maintenance",
        attempt: 1,
        max_attempts: 3
      }

      exhausted = %{
        id: 202,
        worker: inspect(RefreshTraceSummariesWorker),
        queue: "maintenance",
        attempt: 3,
        max_attempts: 3
      }

      {rescued, discarded} =
        ReapStalePeriodicJobsWorker.split_stale_jobs([retryable, exhausted])

      assert rescued == [retryable]
      assert discarded == [exhausted]
    end
  end

  describe "emit_cleanup_telemetry/4" do
    test "publishes rescued and discarded job metadata" do
      handler_id = "periodic-cleanup-#{System.unique_integer([:positive])}"

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

      rescued_job = %{
        id: 11,
        worker: inspect(RefreshTraceSummariesWorker),
        queue: "maintenance",
        attempt: 1,
        max_attempts: 3
      }

      discarded_job = %{
        id: 12,
        worker: inspect(RefreshTraceSummariesWorker),
        queue: "maintenance",
        attempt: 3,
        max_attempts: 3
      }

      assert :ok =
               ReapStalePeriodicJobsWorker.emit_cleanup_telemetry(
                 :completed,
                 [rescued_job],
                 [discarded_job]
               )

      assert_receive {:telemetry, [:serviceradar, :jobs, :periodic_cleanup, :completed],
                      measurements, metadata}

      assert measurements.rescued_count == 1
      assert measurements.discarded_count == 1
      assert metadata.rescued_jobs == [rescued_job]
      assert metadata.discarded_jobs == [discarded_job]
      assert metadata.status == :completed
      assert is_integer(metadata.stale_threshold_minutes)
    end
  end
end
