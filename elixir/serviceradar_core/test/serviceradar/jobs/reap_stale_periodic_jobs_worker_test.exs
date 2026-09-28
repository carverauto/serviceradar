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

  describe "stale_periodic_jobs_query/1" do
    test "matches known self-scheduled singleton workers without cron metadata" do
      query =
        DateTime.utc_now()
        |> ReapStalePeriodicJobsWorker.stale_periodic_jobs_query()
        |> inspect()

      assert query =~ "ServiceRadar.Observability.IpEnrichmentRefreshWorker"
      assert query =~ "ServiceRadar.Observability.GeoLiteMmdbDownloadWorker"
      assert query =~ "ServiceRadar.SweepJobs.SweepMonitorWorker"
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

  describe "periodic_worker_names/0" do
    # Regression: the reaper matched either `meta.cron = "true"` (stamped only by
    # Oban.Plugins.Cron) or a hand-maintained module list. An AshOban trigger
    # enqueues through its own modules with EMPTY meta and was in neither, so a
    # trigger stranded in `executing` blocked its own re-enqueue and nothing could
    # clear it. Assert the AshOban-declared modules are covered, derived rather
    # than listed, so a new trigger cannot silently fall back out of scope.
    test "covers AshOban trigger scheduler and worker modules" do
      names = ReapStalePeriodicJobsWorker.periodic_worker_names()

      declared =
        :serviceradar_core
        |> Application.get_env(:ash_domains, [])
        |> List.wrap()
        |> Enum.flat_map(&Ash.Domain.Info.resources/1)
        |> Enum.uniq()
        |> Enum.flat_map(&AshOban.Info.oban_triggers_and_scheduled_actions/1)
        |> Enum.flat_map(fn trigger ->
          [Map.get(trigger, :scheduler_module_name), Map.get(trigger, :worker_module_name)]
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&inspect/1)
        |> Enum.uniq()

      # There must be something to cover, or this test would pass vacuously.
      refute declared == []

      for module_name <- declared do
        assert module_name in names,
               "AshOban module #{module_name} is not reapable; a stranded run of it would " <>
                 "block its own schedule until the stale threshold elapses"
      end
    end

    test "still covers the explicitly listed self-scheduled workers" do
      names = ReapStalePeriodicJobsWorker.periodic_worker_names()

      assert inspect(RefreshTraceSummariesWorker) in names
    end

    test "returns names in the form stored on oban_jobs.worker" do
      names = ReapStalePeriodicJobsWorker.periodic_worker_names()

      # `to_string/1` on a module atom yields "Elixir."-prefixed output, which would
      # never match the stored worker column.
      refute Enum.any?(names, &String.starts_with?(&1, "Elixir."))
      assert Enum.all?(names, &is_binary/1)
    end
  end
end
