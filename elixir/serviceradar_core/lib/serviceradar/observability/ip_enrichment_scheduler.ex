defmodule ServiceRadar.Observability.IpEnrichmentScheduler do
  @moduledoc """
  Supervisor child that ensures IP enrichment workers are scheduled.

  This keeps scheduling logic out of `ServiceRadar.Application` while still
  enabling per-deployment toggles (repo/oban enabled flags).
  """

  use GenServer

  alias ServiceRadar.Observability.{IpEnrichmentCleanupWorker, IpEnrichmentRefreshWorker}

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, opts)
  end

  @impl GenServer
  def init(state) do
    ensure_jobs()
    {:ok, state}
  end

  defp ensure_jobs do
    case IpEnrichmentRefreshWorker.ensure_scheduled() do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.debug("IP enrichment refresh scheduling skipped", reason: reason)
    end

    case IpEnrichmentCleanupWorker.ensure_scheduled() do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.debug("IP enrichment cleanup scheduling skipped", reason: reason)
    end
  end
end
