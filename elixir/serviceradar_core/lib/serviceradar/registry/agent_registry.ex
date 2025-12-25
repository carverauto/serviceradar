defmodule ServiceRadar.AgentRegistry do
  @moduledoc """
  Distributed registry for tracking connected agents across the ERTS cluster.

  Agents are Go processes that connect to pollers via gRPC. When an agent
  connects, the poller registers it in this registry. The registration
  propagates across the cluster via Horde's CRDT-based synchronization.

  ## Registration Format

  Agents register with a tenant-scoped composite key and connection metadata:

      key = {tenant_id, partition_id, agent_id}
      metadata = %{
        tenant_id: "tenant-uuid",
        partition_id: "partition-1",
        agent_id: "agent-uuid-1234",
        poller_node: :"poller1@192.168.1.20",
        capabilities: [:icmp_sweep, :tcp_sweep, :grpc_checker],
        spiffe_identity: "spiffe://serviceradar/agent/uuid",
        status: :connected,
        connected_at: ~U[2024-01-01 00:00:00Z],
        last_heartbeat: ~U[2024-01-01 00:01:00Z]
      }

  ## Multi-Tenancy

  All lookups are tenant-scoped to ensure isolation:

      # Find all agents for a tenant
      ServiceRadar.AgentRegistry.find_agents_for_tenant("tenant-uuid")

      # Find agents in a tenant's partition
      ServiceRadar.AgentRegistry.find_agents_for_partition("tenant-uuid", "partition-1")

  Legacy single-key lookups (by agent_id string) are supported for backwards
  compatibility but will be deprecated.
  """

  use Horde.Registry

  def start_link(opts) do
    Horde.Registry.start_link(__MODULE__, [keys: :unique] ++ opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    [members: members()]
    |> Keyword.merge(opts)
    |> Horde.Registry.init()
  end

  defp members do
    :auto
  end

  @doc """
  Register an agent with the given key and metadata.

  This is the low-level registration function that accepts any key format
  (string or tuple for partition-namespaced keys).
  """
  @spec register(term(), map()) :: {:ok, pid()} | {:error, {:already_registered, pid()}}
  def register(key, metadata) do
    Horde.Registry.register(__MODULE__, key, metadata)
  end

  @doc """
  Unregister an agent by key.
  """
  @spec unregister(term()) :: :ok
  def unregister(key) do
    Horde.Registry.unregister(__MODULE__, key)
  end

  @doc """
  Update the metadata for a registered agent.
  """
  @spec update_value(term(), (map() -> map())) :: {any(), any()} | :error
  def update_value(key, callback) do
    Horde.Registry.update_value(__MODULE__, key, callback)
  end

  @doc """
  Register an agent with the given agent_id and metadata.

  Called by the poller when an agent connects via gRPC.
  This is a convenience function that constructs metadata from agent_info.
  """
  @spec register_agent(String.t(), map()) :: {:ok, pid()} | {:error, {:already_registered, pid()}}
  def register_agent(agent_id, agent_info) do
    metadata = %{
      agent_id: agent_id,
      poller_node: Node.self(),
      capabilities: Map.get(agent_info, :capabilities, []),
      spiffe_identity: Map.get(agent_info, :spiffe_id),
      status: :connected,
      connected_at: DateTime.utc_now(),
      last_heartbeat: DateTime.utc_now()
    }

    case register(agent_id, metadata) do
      {:ok, _pid} = result ->
        # Broadcast registration event
        Phoenix.PubSub.broadcast(
          ServiceRadar.PubSub,
          "agent:registrations",
          {:agent_registered, metadata}
        )

        result

      error ->
        error
    end
  end

  @doc """
  Unregister an agent when it disconnects.
  """
  @spec unregister_agent(String.t()) :: :ok
  def unregister_agent(agent_id) do
    Horde.Registry.unregister(__MODULE__, agent_id)

    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "agent:registrations",
      {:agent_disconnected, agent_id}
    )

    :ok
  end

  @doc """
  Update agent heartbeat timestamp.
  """
  @spec heartbeat(String.t()) :: :ok | :error
  def heartbeat(agent_id) do
    case Horde.Registry.update_value(__MODULE__, agent_id, fn meta ->
           %{meta | last_heartbeat: DateTime.utc_now()}
         end) do
      {_new, _old} -> :ok
      :error -> :error
    end
  end

  @doc """
  Look up an agent by ID.
  """
  @spec lookup(String.t()) :: map() | nil
  def lookup(agent_id) do
    case Horde.Registry.lookup(__MODULE__, agent_id) do
      [{_pid, metadata}] -> metadata
      [] -> nil
    end
  end

  @doc """
  Find all agents for a specific tenant.

  Uses tenant-scoped lookup to ensure multi-tenant isolation.
  """
  @spec find_agents_for_tenant(String.t()) :: [map()]
  def find_agents_for_tenant(tenant_id) do
    match_spec = [
      {{:"$1", :"$2", %{tenant_id: tenant_id}}, [], [{{:"$1", :"$2"}}]}
    ]

    Horde.Registry.select(__MODULE__, match_spec)
    |> Enum.map(fn {key, pid} ->
      case Horde.Registry.lookup(__MODULE__, key) do
        [{^pid, metadata}] -> Map.put(metadata, :pid, pid)
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Find all agents for a specific tenant and partition.

  Uses tenant-scoped lookup to ensure multi-tenant isolation.
  """
  @spec find_agents_for_partition(String.t(), String.t()) :: [map()]
  def find_agents_for_partition(tenant_id, partition_id) do
    match_spec = [
      {{:"$1", :"$2", %{tenant_id: tenant_id, partition_id: partition_id}}, [], [{{:"$1", :"$2"}}]}
    ]

    Horde.Registry.select(__MODULE__, match_spec)
    |> Enum.map(fn {key, pid} ->
      case Horde.Registry.lookup(__MODULE__, key) do
        [{^pid, metadata}] -> Map.put(metadata, :pid, pid)
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Find all agents connected to a specific poller node.
  """
  @spec find_agents_for_poller(node()) :: [map()]
  def find_agents_for_poller(poller_node) do
    all_agents()
    |> Enum.filter(&(&1.poller_node == poller_node))
  end

  @doc """
  Find all agents connected to a specific poller node within a tenant.
  """
  @spec find_agents_for_poller(String.t(), node()) :: [map()]
  def find_agents_for_poller(tenant_id, poller_node) do
    find_agents_for_tenant(tenant_id)
    |> Enum.filter(&(&1.poller_node == poller_node))
  end

  @doc """
  Find all connected agents across the cluster (all tenants).

  Note: Use tenant-scoped functions for production. This is primarily
  for admin/debugging purposes.
  """
  @spec all_agents() :: [map()]
  def all_agents do
    Horde.Registry.select(__MODULE__, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.map(fn {key, pid, metadata} ->
      Map.merge(metadata, %{key: key, pid: pid})
    end)
  end

  @doc """
  Find agents with specific capabilities within a tenant.
  """
  @spec find_agents_with_capability(String.t(), atom()) :: [map()]
  def find_agents_with_capability(tenant_id, capability) do
    find_agents_for_tenant(tenant_id)
    |> Enum.filter(fn agent ->
      capability in Map.get(agent, :capabilities, [])
    end)
  end

  @doc """
  Find agents with specific capabilities across all tenants.

  Note: Use tenant-scoped version for production.
  """
  @spec find_all_agents_with_capability(atom()) :: [map()]
  def find_all_agents_with_capability(capability) do
    all_agents()
    |> Enum.filter(fn agent ->
      capability in Map.get(agent, :capabilities, [])
    end)
  end

  @doc """
  Count of registered agents.
  """
  @spec count() :: non_neg_integer()
  def count do
    Horde.Registry.count(__MODULE__)
  end
end
