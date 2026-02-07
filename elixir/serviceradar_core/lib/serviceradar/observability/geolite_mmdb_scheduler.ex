defmodule ServiceRadar.Observability.GeoLiteMmdbScheduler do
  @moduledoc """
  Supervisor child that ensures GeoLite MMDB download jobs are scheduled.
  """

  use GenServer

  alias ServiceRadar.Observability.GeoLiteMmdbDownloadWorker

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, opts)
  end

  @impl GenServer
  def init(state) do
    case GeoLiteMmdbDownloadWorker.ensure_scheduled() do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.debug("GeoLite MMDB scheduling skipped", reason: reason)
    end

    {:ok, state}
  end
end
