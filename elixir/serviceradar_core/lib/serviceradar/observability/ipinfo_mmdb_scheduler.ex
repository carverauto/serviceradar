defmodule ServiceRadar.Observability.IpinfoMmdbScheduler do
  @moduledoc """
  Supervisor child that ensures ipinfo lite MMDB download jobs are scheduled.
  """

  use GenServer

  alias ServiceRadar.Observability.IpinfoMmdbDownloadWorker

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, opts)
  end

  @impl GenServer
  def init(state) do
    case IpinfoMmdbDownloadWorker.ensure_scheduled() do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.debug("Ipinfo MMDB scheduling skipped", reason: reason)
    end

    {:ok, state}
  end
end
