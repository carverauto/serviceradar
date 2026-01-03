defmodule ServiceRadar.GatewayRegistry do
  @moduledoc """
  Distributed registry for tracking available agent gateways across the ERTS cluster.

  ## Multi-Tenant Isolation

  Gateways are registered in per-tenant Horde registries managed by
  `ServiceRadar.Cluster.TenantRegistry`. This ensures:

  - Edge components can only discover gateways within their tenant
  - Cross-tenant process enumeration is prevented
  - Each tenant has isolated registry state

  ## Registration Format

  Gateways register with their tenant_id, which routes to the correct registry:

      ServiceRadar.GatewayRegistry.register_gateway(tenant_id, gateway_id, %{
        partition_id: "partition-1",
        domain: "site-a",
        status: :available
      })

  ## Querying Gateways

      # Find all gateways for a tenant (REQUIRED: tenant_id)
      ServiceRadar.GatewayRegistry.find_gateways_for_tenant(tenant_id)

      # Find available gateways for a partition
      ServiceRadar.GatewayRegistry.find_gateways_for_partition(tenant_id, partition_id)
  """

  alias ServiceRadar.Cluster.TenantRegistry

  require Logger

  @doc """
  Register a gateway in its tenant's registry.

  ## Parameters

    - `tenant_id` - Tenant UUID (REQUIRED for multi-tenant isolation)
    - `gateway_id` - Unique gateway identifier
    - `gateway_info` - Gateway metadata map

  ## Examples

      register_gateway("tenant-uuid", "gateway-001", %{
        partition_id: "partition-1",
        domain: "site-a",
        status: :available
      })
  """
  @spec register_gateway(String.t(), String.t(), map()) ::
          {:ok, pid()} | {:error, {:already_registered, pid()} | term()}
  def register_gateway(tenant_id, gateway_id, gateway_info) when is_binary(tenant_id) do
    metadata = %{
      gateway_id: gateway_id,
      tenant_id: tenant_id,
      partition_id: Map.get(gateway_info, :partition_id),
      domain: Map.get(gateway_info, :domain),
      node: Node.self(),
      status: Map.get(gateway_info, :status, :available),
      entity_type: :gateway,
      registered_at: DateTime.utc_now(),
      last_heartbeat: DateTime.utc_now()
    }

    case TenantRegistry.register_gateway(tenant_id, gateway_id, metadata) do
      {:ok, _pid} = result ->
        # Broadcast registration event (tenant-scoped topic)
        Phoenix.PubSub.broadcast(
          ServiceRadar.PubSub,
          "gateway:registrations:#{tenant_id}",
          {:gateway_registered, metadata}
        )

        # Also broadcast to global topic for admin monitoring
        Phoenix.PubSub.broadcast(
          ServiceRadar.PubSub,
          "gateway:registrations",
          {:gateway_registered, metadata}
        )

        Logger.info("Gateway registered: #{gateway_id} for tenant: #{tenant_id}")
        result

      error ->
        Logger.warning("Failed to register gateway #{gateway_id}: #{inspect(error)}")
        error
    end
  end

  # Legacy compatibility: extract tenant_id from gateway_info
  def register_gateway(gateway_id, gateway_info) when is_binary(gateway_id) and is_map(gateway_info) do
    tenant_id = Map.get(gateway_info, :tenant_id)

    if tenant_id do
      register_gateway(tenant_id, gateway_id, gateway_info)
    else
      Logger.warning("register_gateway called without tenant_id")
      {:error, :tenant_id_required}
    end
  end

  @doc """
  Unregister a gateway from its tenant's registry.
  """
  @spec unregister_gateway(String.t(), String.t()) :: :ok
  def unregister_gateway(tenant_id, gateway_id) when is_binary(tenant_id) do
    TenantRegistry.unregister(tenant_id, {:gateway, gateway_id})

    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "gateway:registrations:#{tenant_id}",
      {:gateway_disconnected, gateway_id}
    )

    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "gateway:registrations",
      {:gateway_disconnected, gateway_id, tenant_id}
    )

    :ok
  end

  @doc """
  Update gateway heartbeat timestamp.
  """
  @spec heartbeat(String.t(), String.t()) :: :ok | :error
  def heartbeat(tenant_id, gateway_id) when is_binary(tenant_id) do
    TenantRegistry.gateway_heartbeat(tenant_id, gateway_id)
  end

  @doc """
  Look up a specific gateway in a tenant's registry.
  """
  @spec lookup(String.t(), String.t()) :: [{pid(), map()}]
  def lookup(tenant_id, gateway_id) when is_binary(tenant_id) do
    TenantRegistry.lookup(tenant_id, {:gateway, gateway_id})
  end

  @doc """
  Find all gateways for a specific tenant.

  This is the primary query function - always requires tenant_id.
  """
  @spec find_gateways_for_tenant(String.t()) :: [map()]
  def find_gateways_for_tenant(tenant_id) when is_binary(tenant_id) do
    TenantRegistry.find_gateways(tenant_id)
  end

  @doc """
  Find all gateways for a specific tenant and partition.
  """
  @spec find_gateways_for_partition(String.t(), String.t()) :: [map()]
  def find_gateways_for_partition(tenant_id, partition_id) when is_binary(tenant_id) do
    find_gateways_for_tenant(tenant_id)
    |> Enum.filter(&(&1[:partition_id] == partition_id))
  end

  @doc """
  Find all gateways for a specific tenant and domain.

  Domain represents a logical grouping of gateways, typically by site or location
  (e.g., "site-a", "datacenter-east"). Used for routing checks to gateways
  closest to the target endpoints.
  """
  @spec find_gateways_for_domain(String.t(), String.t()) :: [map()]
  def find_gateways_for_domain(tenant_id, domain) when is_binary(tenant_id) do
    find_gateways_for_tenant(tenant_id)
    |> Enum.filter(&(&1[:domain] == domain))
  end

  @doc """
  Find an available gateway for a tenant's domain.

  Returns `{:ok, metadata}` if found, `{:error, :no_available_gateway}` otherwise.
  The returned metadata includes the `:pid` from Horde for cross-node dispatch.
  """
  @spec find_available_gateway_for_domain(String.t(), String.t()) ::
          {:ok, map()} | {:error, :no_available_gateway}
  def find_available_gateway_for_domain(tenant_id, domain) do
    gateways = find_gateways_for_domain(tenant_id, domain)

    case Enum.find(gateways, &(&1[:status] == :available)) do
      nil -> {:error, :no_available_gateway}
      gateway -> {:ok, gateway}
    end
  end

  @doc """
  Find an available gateway for a tenant's partition.

  Returns `{:ok, metadata}` if found, `{:error, :no_available_gateway}` otherwise.
  The returned metadata includes the `:pid` from Horde for cross-node dispatch.
  """
  @spec find_available_gateway_for_partition(String.t(), String.t()) ::
          {:ok, map()} | {:error, :no_available_gateway}
  def find_available_gateway_for_partition(tenant_id, partition_id) do
    gateways = find_gateways_for_partition(tenant_id, partition_id)

    case Enum.find(gateways, &(&1[:status] == :available)) do
      nil -> {:error, :no_available_gateway}
      gateway -> {:ok, gateway}
    end
  end

  @doc """
  Find all available gateways for a tenant.
  """
  @spec find_available_gateways(String.t()) :: [map()]
  def find_available_gateways(tenant_id) when is_binary(tenant_id) do
    TenantRegistry.find_available_gateways(tenant_id)
  end

  @doc """
  Get all registered gateways across ALL tenants.

  WARNING: Admin/platform use only.
  """
  @spec all_gateways() :: [map()]
  def all_gateways do
    # For admin, query Ash for all gateways in database
    case Ash.read(ServiceRadar.Infrastructure.Gateway, authorize?: false) do
      {:ok, gateways} -> gateways
      _ -> []
    end
  rescue
    _ -> []
  end

  @doc """
  Count of registered gateways for a tenant.
  """
  @spec count(String.t()) :: non_neg_integer()
  def count(tenant_id) when is_binary(tenant_id) do
    TenantRegistry.count_by_type(tenant_id, :gateway)
  end

  @doc """
  Count of registered gateways across all tenants.

  WARNING: Admin/platform use only.
  """
  @spec count() :: non_neg_integer()
  def count do
    TenantRegistry.list_registries()
    |> Enum.reduce(0, fn {_name, _pid}, acc ->
      acc
    end)
  end
end
