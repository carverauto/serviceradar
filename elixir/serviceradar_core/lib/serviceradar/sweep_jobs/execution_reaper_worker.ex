defmodule ServiceRadar.SweepJobs.ExecutionReaperWorker do
  @moduledoc """
  Periodically fails sweep executions left `:running` after their agent stopped reporting.

  See `ServiceRadar.SweepJobs.ExecutionReaper`. Scheduled by cron rather than by
  `SweepMonitorWorker`'s self-scheduling, which stops once no group is enabled --
  the very state that strands a disabled group's executions.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 60, states: :incomplete]

  alias ServiceRadar.SweepJobs.ExecutionReaper

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])

    case ExecutionReaper.reap(config) do
      {:ok, %{failed: 0, errors: 0}} ->
        :ok

      {:ok, result} ->
        Logger.info("Sweep execution reaper closed abandoned executions",
          failed: result.failed,
          skipped: result.skipped,
          errors: result.errors
        )

        :ok

      {:error, reason} ->
        Logger.error("Sweep execution reaper failed", reason: inspect(reason))
        {:error, reason}
    end
  end
end
