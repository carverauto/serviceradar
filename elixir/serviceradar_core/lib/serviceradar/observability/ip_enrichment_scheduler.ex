defmodule ServiceRadar.Observability.IpEnrichmentScheduler do
  @moduledoc """
  Supervisor child that ensures IP enrichment workers are scheduled.

  This keeps scheduling logic out of `ServiceRadar.Application` while still
  enabling per-deployment toggles (repo/oban enabled flags).
  """

  use GenServer

  alias ServiceRadar.Observability.{IpEnrichmentCleanupWorker, IpEnrichmentRefreshWorker}
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, opts)
  end

  @impl GenServer
  def init(state) do
    send(self(), :ensure_jobs)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:ensure_jobs, state) do
    ensure_jobs()
    Process.send_after(self(), :ensure_jobs, 60_000)
    {:noreply, state}
  end

  defp ensure_jobs do
    if not oban_jobs_ready?() do
      Logger.debug("IP enrichment scheduling skipped; Oban tables not ready")
      :ok
    else
      do_ensure_jobs()
    end
  end

  defp do_ensure_jobs do
    case IpEnrichmentRefreshWorker.ensure_scheduled() do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.debug("IP enrichment refresh scheduling skipped", reason: reason)
    end

    case IpEnrichmentCleanupWorker.ensure_scheduled() do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.debug("IP enrichment cleanup scheduling skipped", reason: reason)
    end
  end

  defp oban_jobs_ready? do
    if ObanSupport.available?() do
      prefix = ObanSupport.prefix()

      case Ecto.Adapters.SQL.query(Repo, "SELECT to_regclass($1)", ["#{prefix}.oban_jobs"]) do
        {:ok, %{rows: [[nil]]}} -> false
        {:ok, _} -> true
        {:error, _} -> false
      end
    else
      false
    end
  rescue
    _ -> false
  end
end
