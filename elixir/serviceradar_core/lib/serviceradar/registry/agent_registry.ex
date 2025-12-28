defmodule ServiceRadar.AgentRegistry do
  @moduledoc """
  Distributed registry for tracking connected agents across the ERTS cluster.

  ## Multi-Tenant Isolation

  Agents are registered in per-tenant Horde registries managed by
  `ServiceRadar.Cluster.TenantRegistry`. This ensures:

  - Edge components can only discover agents within their tenant
  - Cross-tenant process enumeration is prevented
  - Each tenant has isolated registry state

  ## Registration Format

  Agents register with their tenant_id, which routes to the correct registry:

      ServiceRadar.AgentRegistry.register_agent(tenant_id, agent_id, %{
        partition_id: "partition-1",
        poller_node: node(),
        capabilities: [:icmp_sweep, :tcp_sweep],
        status: :connected
      })

  ## Querying Agents

      # Find all agents for a tenant (REQUIRED: tenant_id)
      ServiceRadar.AgentRegistry.find_agents_for_tenant(tenant_id)

      # Find agents for a partition
      ServiceRadar.AgentRegistry.find_agents_for_partition(tenant_id, partition_id)

  ## Legacy Compatibility

  This module maintains backwards compatibility with the old single-registry
  API while delegating to per-tenant registries. The `all_agents/0` function
  is retained for admin purposes but iterates across all tenant registries.
  """

  alias ServiceRadar.Cluster.TenantRegistry

  require Logger

  @doc """
  Register an agent in its tenant's registry.

  ## Parameters

    - `tenant_id` - Tenant UUID (REQUIRED for multi-tenant isolation)
    - `agent_id` - Unique agent identifier
    - `agent_info` - Agent metadata map

  ## Examples

      register_agent("tenant-uuid", "agent-001", %{
        partition_id: "partition-1",
        poller_node: node(),
        capabilities: [:icmp_sweep, :tcp_sweep],
        status: :connected
      })
  """
  @spec register_agent(String.t(), String.t(), map()) ::
          {:ok, pid()} | {:error, {:already_registered, pid()} | term()}
  def register_agent(tenant_id, agent_id, agent_info) when is_binary(tenant_id) do
    metadata = %{
      agent_id: agent_id,
      tenant_id: tenant_id,
      partition_id: Map.get(agent_info, :partition_id),
      poller_node: Map.get(agent_info, :poller_node, Node.self()),
      capabilities: Map.get(agent_info, :capabilities, []),
      spiffe_identity: Map.get(agent_info, :spiffe_id),
      node: Node.self(),
      status: Map.get(agent_info, :status, :connected),
      connected_at: DateTime.utc_now(),
      last_heartbeat: DateTime.utc_now()
    }

    case TenantRegistry.register_agent(tenant_id, agent_id, metadata) do
      {:ok, _pid} = result ->
        # Broadcast registration event (tenant-scoped topic)
        Phoenix.PubSub.broadcast(
          ServiceRadar.PubSub,
          "agent:registrations:#{tenant_id}",
          {:agent_registered, metadata}
        )

        # Also broadcast to global topic for admin monitoring
        Phoenix.PubSub.broadcast(
          ServiceRadar.PubSub,
          "agent:registrations",
          {:agent_registered, metadata}
        )

        Logger.info("Agent registered: #{agent_id} for tenant: #{tenant_id}")
        result

      error ->
        Logger.warning("Failed to register agent #{agent_id}: #{inspect(error)}")
        error
    end
  end

  # Legacy compatibility: extract tenant_id from agent_info
  def register_agent(agent_id, agent_info) when is_binary(agent_id) and is_map(agent_info) do
    tenant_id = Map.get(agent_info, :tenant_id)

    if tenant_id do
      register_agent(tenant_id, agent_id, agent_info)
    else
      Logger.warning("register_agent called without tenant_id - tenant_id is required")
      {:error, :tenant_id_required}
    end
  end

  @doc """
  Unregister an agent from its tenant's registry.
  """
  @spec unregister_agent(String.t(), String.t()) :: :ok
  def unregister_agent(tenant_id, agent_id) when is_binary(tenant_id) do
    TenantRegistry.unregister(tenant_id, {:agent, agent_id})

    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "agent:registrations:#{tenant_id}",
      {:agent_disconnected, agent_id}
    )

    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "agent:registrations",
      {:agent_disconnected, agent_id, tenant_id}
    )

    :ok
  end

  # Legacy compatibility
  def unregister_agent(agent_id) when is_binary(agent_id) do
    Logger.warning("unregister_agent called without tenant_id - operation may not work correctly")
    :ok
  end

  @doc """
  Update agent heartbeat timestamp.
  """
  @spec heartbeat(String.t(), String.t()) :: :ok | :error
  def heartbeat(tenant_id, agent_id) when is_binary(tenant_id) do
    case TenantRegistry.update_value(tenant_id, {:agent, agent_id}, fn meta ->
           %{meta | last_heartbeat: DateTime.utc_now()}
         end) do
      {_new, _old} -> :ok
      :error -> :error
    end
  end

  @doc """
  Look up a specific agent in a tenant's registry.
  """
  @spec lookup(String.t(), String.t()) :: [{pid(), map()}]
  def lookup(tenant_id, agent_id) when is_binary(tenant_id) do
    TenantRegistry.lookup(tenant_id, {:agent, agent_id})
  end

  @doc """
  Find all agents for a specific tenant.

  This is the primary query function - always requires tenant_id.
  """
  @spec find_agents_for_tenant(String.t()) :: [map()]
  def find_agents_for_tenant(tenant_id) when is_binary(tenant_id) do
    TenantRegistry.find_agents(tenant_id)
  end

  @doc """
  Find all agents for a specific tenant and partition.
  """
  @spec find_agents_for_partition(String.t(), String.t()) :: [map()]
  def find_agents_for_partition(tenant_id, partition_id) when is_binary(tenant_id) do
    find_agents_for_tenant(tenant_id)
    |> Enum.filter(&(&1[:partition_id] == partition_id))
  end

  @doc """
  Find agents connected to a specific poller node within a tenant.
  """
  @spec find_agents_for_poller(String.t(), node()) :: [map()]
  def find_agents_for_poller(tenant_id, poller_node) when is_binary(tenant_id) do
    find_agents_for_tenant(tenant_id)
    |> Enum.filter(&(&1[:poller_node] == poller_node))
  end

  @doc """
  Find agents with specific capabilities within a tenant.
  """
  @spec find_agents_with_capability(String.t(), atom()) :: [map()]
  def find_agents_with_capability(tenant_id, capability) when is_binary(tenant_id) do
    find_agents_for_tenant(tenant_id)
    |> Enum.filter(fn agent ->
      capability in Map.get(agent, :capabilities, [])
    end)
  end

  @doc """
  Get all registered agents across ALL tenants.

  WARNING: This is for admin/platform use only. Edge components should
  NEVER call this function - use tenant-scoped queries instead.

  Queries the database as source of truth for admin views.
  """
  @spec all_agents() :: [map()]
  def all_agents do
    # For admin, query Ash for all agents in database
    # Registry state is for runtime/clustering, DB is source of truth
    case Ash.read(ServiceRadar.Infrastructure.Agent, authorize?: false) do
      {:ok, agents} -> agents
      _ -> []
    end
  end

  @doc """
  Count of registered agents for a tenant.
  """
  @spec count(String.t()) :: non_neg_integer()
  def count(tenant_id) when is_binary(tenant_id) do
    TenantRegistry.count_by_type(tenant_id, :agent)
  end

  @doc """
  Count of registered agents across all tenants.

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
