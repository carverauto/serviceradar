defmodule ServiceRadar.Observability.NetflowSecurityScheduler do
  @moduledoc """
  Ensures optional NetFlow security intelligence jobs are scheduled when Oban is available.
  """

  use GenServer

  alias ServiceRadar.Observability.{NetflowSecurityRefreshWorker, ThreatIntelFeedRefreshWorker}
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl GenServer
  def init(state) do
    # Schedule immediately on startup, then periodically.
    send(self(), :schedule)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:schedule, state) do
    ensure_scheduled(ThreatIntelFeedRefreshWorker)
    ensure_scheduled(NetflowSecurityRefreshWorker)

    # Re-check periodically; Oban may come up after app boot.
    Process.send_after(self(), :schedule, 60_000)
    {:noreply, state}
  end

  defp ensure_scheduled(worker) do
    if oban_jobs_ready?() do
      case worker.ensure_scheduled() do
        {:ok, :already_scheduled} ->
          :ok

        {:ok, _job} ->
          :ok

        {:error, reason} ->
          Logger.debug("NetFlow security scheduler skipped",
            worker: inspect(worker),
            reason: inspect(reason)
          )
      end
    else
      Logger.debug("NetFlow security scheduler skipped; Oban tables not ready",
        worker: inspect(worker)
      )
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
