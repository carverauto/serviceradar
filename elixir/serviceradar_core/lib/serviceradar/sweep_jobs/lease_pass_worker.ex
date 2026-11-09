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
  alias ServiceRadar.SweepJobs.RecoveryRetryIntents

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    started_at = DateTime.utc_now()

    case LeasePass.run(started_at) do
      {:ok, summary} ->
        if summary.scheduled + summary.dropped + summary.revoked + summary.pushed +
             summary.withdrawn + summary.missed_offline + summary.missed_exhausted +
             summary.errors > 0 do
          Logger.info("Sweep lease pass: #{inspect(summary)}")
        end

        if summary.errors == 0 do
          case RecoveryRetryIntents.reconciled_before(started_at) do
            {:ok, _count} -> :ok
            {:error, _} = error -> error
          end
        else
          :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
