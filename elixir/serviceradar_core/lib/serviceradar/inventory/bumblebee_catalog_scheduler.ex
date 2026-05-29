defmodule ServiceRadar.Inventory.BumblebeeCatalogScheduler do
  @moduledoc """
  Coordinator-owned scheduler shim for Bumblebee catalog refresh jobs.
  """

  use GenServer

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    send(self(), :ensure_scheduled)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:ensure_scheduled, state) do
    case ServiceRadar.Inventory.BumblebeeCatalogRefreshWorker.ensure_scheduled() do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to schedule Bumblebee catalog refresh", reason: inspect(reason))
    end

    {:noreply, state}
  end
end
