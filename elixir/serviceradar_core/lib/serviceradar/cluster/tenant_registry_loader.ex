defmodule ServiceRadar.Cluster.TenantRegistryLoader do
  @moduledoc """
  Loads tenant slug mappings into the in-memory TenantRegistry table on startup.

  This ensures edge components can resolve tenant slugs to IDs via the cluster
  without requiring direct database access.
  """

  use GenServer

  require Logger
  require Ash.Query

  alias ServiceRadar.Cluster.TenantRegistry
  alias ServiceRadar.Identity.Tenant

  @retry_delay_ms :timer.seconds(5)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if repo_enabled?() do
      send(self(), :load_slugs)
    else
      Logger.debug("[TenantRegistryLoader] Repo disabled; skipping slug preload")
    end

    {:ok, %{loaded?: false}}
  end

  @impl true
  def handle_info(:load_slugs, state) do
    case load_slugs() do
      :ok ->
        {:noreply, %{state | loaded?: true}}

      {:error, reason} ->
        Logger.warning(
          "[TenantRegistryLoader] Failed to preload tenant slugs: #{inspect(reason)}; retrying"
        )

        Process.send_after(self(), :load_slugs, @retry_delay_ms)
        {:noreply, state}
    end
  end

  defp load_slugs do
    query =
      Tenant
      |> Ash.Query.for_read(:read)
      |> Ash.Query.select([:id, :slug])

    case Ash.read(query, authorize?: false) do
      {:ok, tenants} ->
        Enum.each(tenants, fn tenant ->
          TenantRegistry.register_slug(to_string(tenant.slug), tenant.id)
        end)

        Logger.info("[TenantRegistryLoader] Loaded #{length(tenants)} tenant slugs")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp repo_enabled? do
    Application.get_env(:serviceradar_core, :repo_enabled, true) &&
      Process.whereis(ServiceRadar.Repo)
  end
end
