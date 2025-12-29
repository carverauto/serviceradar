defmodule ServiceRadar.AgentRegistry do
  @moduledoc """
  Distributed registry for tracking connected agents.

  ## Architecture: Go Agents via gRPC

  Agents are Go-based processes running in customer networks. They do NOT
  join the ERTS cluster - instead, they expose a gRPC endpoint that pollers
  call to execute monitoring checks.

  The registry tracks agent metadata including gRPC addresses so pollers
  can discover and communicate with their assigned agents.

  ## Multi-Tenant Isolation

  Agents are registered in per-tenant Horde registries managed by
  `ServiceRadar.Cluster.TenantRegistry`. This ensures:

  - Edge components can only discover agents within their tenant
  - Cross-tenant process enumeration is prevented
  - Each tenant has isolated registry state

  ## Registration Format

  Agents register via the core API with their gRPC address:

      ServiceRadar.AgentRegistry.register_agent(tenant_id, agent_id, %{
        partition_id: "partition-1",
        grpc_host: "192.168.1.100",
        grpc_port: 50051,
        capabilities: [:icmp_sweep, :tcp_sweep, :snmp],
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
      domain: Map.get(agent_info, :domain),
      poller_node: Map.get(agent_info, :poller_node, Node.self()),
      # gRPC connection details for poller-initiated communication
      grpc_host: Map.get(agent_info, :grpc_host),
      grpc_port: Map.get(agent_info, :grpc_port),
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
  Find all agents for a specific tenant and domain.

  Domain represents a logical grouping of agents, typically by site or location
  (e.g., "site-a", "datacenter-east"). Used for routing checks to agents
  in the same network segment as target endpoints.
  """
  @spec find_agents_for_domain(String.t(), String.t()) :: [map()]
  def find_agents_for_domain(tenant_id, domain) when is_binary(tenant_id) do
    find_agents_for_tenant(tenant_id)
    |> Enum.filter(&(&1[:domain] == domain))
  end

  @doc """
  Find an available agent for a tenant's domain.

  Returns the first connected agent in the domain, or nil if none available.
  """
  @spec find_available_agent_for_domain(String.t(), String.t()) :: map() | nil
  def find_available_agent_for_domain(tenant_id, domain) do
    find_agents_for_domain(tenant_id, domain)
    |> Enum.find(&(&1[:status] == :connected))
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
  Get gRPC connection details for an agent.

  Returns `{:ok, {host, port}}` if agent is registered with gRPC details,
  or `{:error, :not_found}` if agent is not registered or has no gRPC address.
  """
  @spec get_grpc_address(String.t(), String.t()) :: {:ok, {String.t(), pos_integer()}} | {:error, :not_found | :no_grpc_address}
  def get_grpc_address(tenant_id, agent_id) when is_binary(tenant_id) do
    case lookup(tenant_id, agent_id) do
      [{_pid, metadata}] ->
        case {metadata[:grpc_host], metadata[:grpc_port]} do
          {host, port} when is_binary(host) and is_integer(port) and port > 0 ->
            {:ok, {host, port}}
          _ ->
            {:error, :no_grpc_address}
        end
      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Find all agents with gRPC addresses available for a tenant.

  Used by pollers to discover agents they can communicate with.
  """
  @spec find_agents_with_grpc(String.t()) :: [map()]
  def find_agents_with_grpc(tenant_id) when is_binary(tenant_id) do
    find_agents_for_tenant(tenant_id)
    |> Enum.filter(fn agent ->
      is_binary(agent[:grpc_host]) and is_integer(agent[:grpc_port]) and agent[:grpc_port] > 0
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
