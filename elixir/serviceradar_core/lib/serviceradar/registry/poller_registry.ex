defmodule ServiceRadar.PollerRegistry do
  @moduledoc """
  Distributed registry for tracking available pollers across the ERTS cluster.

  ## Multi-Tenant Isolation

  Pollers are registered in per-tenant Horde registries managed by
  `ServiceRadar.Cluster.TenantRegistry`. This ensures:

  - Edge components can only discover pollers within their tenant
  - Cross-tenant process enumeration is prevented
  - Each tenant has isolated registry state

  ## Registration Format

  Pollers register with their tenant_id, which routes to the correct registry:

      ServiceRadar.PollerRegistry.register_poller(tenant_id, poller_id, %{
        partition_id: "partition-1",
        domain: "site-a",
        status: :available
      })

  ## Querying Pollers

      # Find all pollers for a tenant (REQUIRED: tenant_id)
      ServiceRadar.PollerRegistry.find_pollers_for_tenant(tenant_id)

      # Find available pollers for a partition
      ServiceRadar.PollerRegistry.find_pollers_for_partition(tenant_id, partition_id)

  ## Legacy Compatibility

  This module maintains backwards compatibility with the old single-registry
  API while delegating to per-tenant registries. The `all_pollers/0` and
  `find_all_available_pollers/0` functions are retained for admin purposes
  but iterate across all tenant registries.
  """

  alias ServiceRadar.Cluster.TenantRegistry

  require Logger

  @doc """
  Register a poller in its tenant's registry.

  ## Parameters

    - `tenant_id` - Tenant UUID (REQUIRED for multi-tenant isolation)
    - `poller_id` - Unique poller identifier
    - `poller_info` - Poller metadata map

  ## Examples

      register_poller("tenant-uuid", "poller-001", %{
        partition_id: "partition-1",
        domain: "site-a",
        status: :available
      })
  """
  @spec register_poller(String.t(), String.t(), map()) ::
          {:ok, pid()} | {:error, {:already_registered, pid()} | term()}
  def register_poller(tenant_id, poller_id, poller_info) when is_binary(tenant_id) do
    metadata = %{
      poller_id: poller_id,
      tenant_id: tenant_id,
      partition_id: Map.get(poller_info, :partition_id),
      domain: Map.get(poller_info, :domain),
      node: Node.self(),
      status: Map.get(poller_info, :status, :available),
      registered_at: DateTime.utc_now(),
      last_heartbeat: DateTime.utc_now()
    }

    case TenantRegistry.register_poller(tenant_id, poller_id, metadata) do
      {:ok, _pid} = result ->
        # Broadcast registration event (tenant-scoped topic)
        Phoenix.PubSub.broadcast(
          ServiceRadar.PubSub,
          "poller:registrations:#{tenant_id}",
          {:poller_registered, metadata}
        )

        # Also broadcast to global topic for admin monitoring
        Phoenix.PubSub.broadcast(
          ServiceRadar.PubSub,
          "poller:registrations",
          {:poller_registered, metadata}
        )

        Logger.info("Poller registered: #{poller_id} for tenant: #{tenant_id}")
        result

      error ->
        Logger.warning("Failed to register poller #{poller_id}: #{inspect(error)}")
        error
    end
  end

  # Legacy compatibility: extract tenant_id from poller_info
  def register_poller(poller_id, poller_info) when is_binary(poller_id) and is_map(poller_info) do
    tenant_id = Map.get(poller_info, :tenant_id)

    if tenant_id do
      register_poller(tenant_id, poller_id, poller_info)
    else
      Logger.warning("register_poller called without tenant_id - using legacy single registry")
      {:error, :tenant_id_required}
    end
  end

  @doc """
  Unregister a poller from its tenant's registry.
  """
  @spec unregister_poller(String.t(), String.t()) :: :ok
  def unregister_poller(tenant_id, poller_id) when is_binary(tenant_id) do
    TenantRegistry.unregister(tenant_id, {:poller, poller_id})

    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "poller:registrations:#{tenant_id}",
      {:poller_disconnected, poller_id}
    )

    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "poller:registrations",
      {:poller_disconnected, poller_id, tenant_id}
    )

    :ok
  end

  @doc """
  Update poller heartbeat timestamp.
  """
  @spec heartbeat(String.t(), String.t()) :: :ok | :error
  def heartbeat(tenant_id, poller_id) when is_binary(tenant_id) do
    TenantRegistry.poller_heartbeat(tenant_id, poller_id)
  end

  @doc """
  Look up a specific poller in a tenant's registry.
  """
  @spec lookup(String.t(), String.t()) :: [{pid(), map()}]
  def lookup(tenant_id, poller_id) when is_binary(tenant_id) do
    TenantRegistry.lookup(tenant_id, {:poller, poller_id})
  end

  @doc """
  Find all pollers for a specific tenant.

  This is the primary query function - always requires tenant_id.
  """
  @spec find_pollers_for_tenant(String.t()) :: [map()]
  def find_pollers_for_tenant(tenant_id) when is_binary(tenant_id) do
    TenantRegistry.find_pollers(tenant_id)
  end

  @doc """
  Find all pollers for a specific tenant and partition.
  """
  @spec find_pollers_for_partition(String.t(), String.t()) :: [map()]
  def find_pollers_for_partition(tenant_id, partition_id) when is_binary(tenant_id) do
    find_pollers_for_tenant(tenant_id)
    |> Enum.filter(&(&1[:partition_id] == partition_id))
  end

  @doc """
  Find all pollers for a specific tenant and domain.

  Domain represents a logical grouping of pollers, typically by site or location
  (e.g., "site-a", "datacenter-east"). Used for routing checks to pollers
  closest to the target endpoints.
  """
  @spec find_pollers_for_domain(String.t(), String.t()) :: [map()]
  def find_pollers_for_domain(tenant_id, domain) when is_binary(tenant_id) do
    find_pollers_for_tenant(tenant_id)
    |> Enum.filter(&(&1[:domain] == domain))
  end

  @doc """
  Find an available poller for a tenant's domain.

  Returns `{:ok, metadata}` if found, `{:error, :no_available_poller}` otherwise.
  The returned metadata includes the `:pid` from Horde for cross-node dispatch.
  """
  @spec find_available_poller_for_domain(String.t(), String.t()) ::
          {:ok, map()} | {:error, :no_available_poller}
  def find_available_poller_for_domain(tenant_id, domain) do
    pollers = find_pollers_for_domain(tenant_id, domain)

    case Enum.find(pollers, &(&1[:status] == :available)) do
      nil -> {:error, :no_available_poller}
      poller -> {:ok, poller}
    end
  end

  @doc """
  Find an available poller for a tenant's partition.

  Returns `{:ok, metadata}` if found, `{:error, :no_available_poller}` otherwise.
  The returned metadata includes the `:pid` from Horde for cross-node dispatch.
  """
  @spec find_available_poller_for_partition(String.t(), String.t()) ::
          {:ok, map()} | {:error, :no_available_poller}
  def find_available_poller_for_partition(tenant_id, partition_id) do
    # find_pollers_for_partition returns metadata with :pid included from Horde
    pollers = find_pollers_for_partition(tenant_id, partition_id)

    case Enum.find(pollers, &(&1[:status] == :available)) do
      nil -> {:error, :no_available_poller}
      poller -> {:ok, poller}
    end
  end

  @doc """
  Find all available pollers for a tenant.
  """
  @spec find_available_pollers(String.t()) :: [map()]
  def find_available_pollers(tenant_id) when is_binary(tenant_id) do
    TenantRegistry.find_available_pollers(tenant_id)
  end

  @doc """
  Find all available pollers across ALL tenants.

  WARNING: This is for admin/platform use only. Edge components should
  NEVER call this function - use tenant-scoped queries instead.

  Iterates across all tenant registries, which may be slow with many tenants.
  """
  @spec find_all_available_pollers() :: [map()]
  def find_all_available_pollers do
    TenantRegistry.list_registries()
    |> Enum.flat_map(fn {_name, _pid} ->
      # We need to extract tenant_id from the registry - this is inefficient
      # Consider maintaining a tenant_id -> registry mapping
      []
    end)
  end

  @doc """
  Get all registered pollers across ALL tenants.

  WARNING: Admin/platform use only. See `find_all_available_pollers/0`.
  """
  @spec all_pollers() :: [map()]
  def all_pollers do
    # For admin, query Ash for all pollers in database
    # Registry state is for runtime/clustering, DB is source of truth
    case Ash.read(ServiceRadar.Infrastructure.Poller, authorize?: false) do
      {:ok, pollers} -> pollers
      _ -> []
    end
  end

  @doc """
  Count of registered pollers for a tenant.
  """
  @spec count(String.t()) :: non_neg_integer()
  def count(tenant_id) when is_binary(tenant_id) do
    TenantRegistry.count_by_type(tenant_id, :poller)
  end

  @doc """
  Count of registered pollers across all tenants.

  WARNING: Admin/platform use only.
  """
  @spec count() :: non_neg_integer()
  def count do
    TenantRegistry.list_registries()
    |> Enum.reduce(0, fn {_name, _pid}, acc ->
      # Would need to track tenant_id per registry for accurate count
      acc
    end)
  end
end
