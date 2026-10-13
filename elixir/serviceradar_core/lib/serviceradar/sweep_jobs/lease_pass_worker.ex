defmodule ServiceRadar.SweepJobs.LeasePassWorker do
  @moduledoc """
  Runs `ServiceRadar.SweepJobs.LeasePass` from the Oban crontab every five minutes, which keeps
  a connected agent's lease horizon full and applies group, agent and setting changes.

  The pass is idempotent, so a skipped or failed run is caught up by the next one.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: 240, states: :incomplete]

  alias ServiceRadar.SweepJobs.LeasePass

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    case LeasePass.run() do
      {:ok, :idle} ->
        :ok

      {:ok, summary} ->
        if summary.scheduled + summary.dropped + summary.revoked + summary.pushed +
             summary.withdrawn + summary.errors > 0 do
          Logger.info("Sweep lease pass: #{inspect(summary)}")
        end

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
