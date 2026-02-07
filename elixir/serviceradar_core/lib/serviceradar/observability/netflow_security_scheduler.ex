defmodule ServiceRadar.Observability.NetflowSecurityScheduler do
  @moduledoc """
  Ensures optional NetFlow security intelligence jobs are scheduled when Oban is available.
  """

  use GenServer

  alias ServiceRadar.Observability.{NetflowSecurityRefreshWorker, ThreatIntelFeedRefreshWorker}

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
  end
end
