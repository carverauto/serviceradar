defmodule ServiceRadar.NetworkDiscovery.MapperConfigMigratorWorker do
  @moduledoc """
  Runs a one-time migration from legacy mapper KV config into Ash resources.
  """

  use GenServer

  require Logger

  alias ServiceRadar.NetworkDiscovery.MapperConfigMigrator

  @migrate_delay_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :migrate, @migrate_delay_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:migrate, state) do
    migrate_from_kv()
    {:noreply, state}
  end

  defp migrate_from_kv do
    if repo_enabled?() && datasvc_enabled?() do
      case MapperConfigMigrator.migrate_from_kv() do
        {:ok, 0} ->
          Logger.debug("Mapper config migration: no legacy config found")

        {:ok, count} ->
          Logger.info("Mapper config migration: imported #{count} job(s) from KV")

        {:error, reason} ->
          Logger.warning("Mapper config migration failed: #{inspect(reason)}")
      end
    end
  end

  defp repo_enabled? do
    Application.get_env(:serviceradar_core, :repo_enabled, true) &&
      Process.whereis(ServiceRadar.Repo)
  end

  defp datasvc_enabled? do
    Application.get_env(:serviceradar_core, :datasvc_enabled, true) &&
      Process.whereis(ServiceRadar.DataService.Client)
  end
end
