defmodule ServiceRadar.AgentRegistry do
  @moduledoc """
  Registry for tracking connected agents.

  ## Architecture: Go Agents via gRPC

  Agents are Go-based processes running in customer networks. They do NOT
  join the ERTS cluster - instead, they expose a gRPC endpoint that gateways
  call to execute monitoring checks.

  The registry tracks agent metadata including gRPC addresses so gateways
  can discover and communicate with their assigned agents.

  This module provides agent discovery for the local instance. Each tenant
  deployment runs independently with its own infrastructure.

  ## Registration

      ServiceRadar.AgentRegistry.register_agent("agent-001", %{
        partition_id: "partition-1",
        grpc_host: "192.168.1.100",
        grpc_port: 50_051,
        capabilities: [:icmp_sweep, :tcp_sweep, :snmp],
        status: :connected
      })

  ## Querying Agents

      # Find all agents
      ServiceRadar.AgentRegistry.find_agents()

      # Find agents for a partition
      ServiceRadar.AgentRegistry.find_agents_for_partition(partition_id)
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.ProcessRegistry

  require Logger

  @doc """
  Register an agent in the registry.

  ## Parameters

    - `agent_id` - Unique agent identifier
    - `agent_info` - Agent metadata map

  ## Examples

      register_agent("agent-001", %{
        partition_id: "partition-1",
        gateway_node: node(),
        capabilities: [:icmp_sweep, :tcp_sweep],
        status: :connected
      })
  """
  @spec register_agent(String.t(), map()) ::
          {:ok, pid()} | {:error, {:already_registered, pid()} | term()}
  def register_agent(agent_id, agent_info) when is_binary(agent_id) do
    metadata = %{
      agent_id: agent_id,
      partition_id: Map.get(agent_info, :partition_id),
      domain: Map.get(agent_info, :domain),
      gateway_node: Map.get(agent_info, :gateway_node, Node.self()),
      grpc_host: Map.get(agent_info, :grpc_host),
      grpc_port: Map.get(agent_info, :grpc_port),
      capabilities: Map.get(agent_info, :capabilities, []),
      spiffe_identity: Map.get(agent_info, :spiffe_id),
      node: Node.self(),
      status: Map.get(agent_info, :status, :connected),
      connected_at: DateTime.utc_now(),
      last_heartbeat: DateTime.utc_now()
    }

    case ProcessRegistry.register_agent(agent_id, metadata) do
      {:ok, _pid} = result ->
        Phoenix.PubSub.broadcast(
          ServiceRadar.PubSub,
          "agent:registrations",
          {:agent_registered, metadata}
        )

        Logger.info("Agent registered: #{agent_id}")
        result

      error ->
        Logger.warning("Failed to register agent #{agent_id}: #{inspect(error)}")
        error
    end
  end

  @doc """
  Unregister an agent from the registry.
  """
  @spec unregister_agent(String.t()) :: :ok
  def unregister_agent(agent_id) when is_binary(agent_id) do
    ProcessRegistry.unregister({:agent, agent_id})

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
  def heartbeat(agent_id) when is_binary(agent_id) do
    ProcessRegistry.agent_heartbeat(agent_id)
  end

  @doc """
  Look up a specific agent in the registry.
  """
  @spec lookup(String.t()) :: [{pid(), map()}]
  def lookup(agent_id) when is_binary(agent_id) do
    ProcessRegistry.lookup({:agent, agent_id})
  end

  @doc """
  Find all agents.
  """
  @spec find_agents() :: [map()]
  def find_agents do
    ProcessRegistry.find_agents()
  end

  @doc """
  Find all agents for a specific partition.
  """
  @spec find_agents_for_partition(String.t()) :: [map()]
  def find_agents_for_partition(partition_id) do
    find_agents()
    |> Enum.filter(&(&1[:partition_id] == partition_id))
  end

  @doc """
  Find all agents for a specific domain.
  """
  @spec find_agents_for_domain(String.t()) :: [map()]
  def find_agents_for_domain(domain) do
    find_agents()
    |> Enum.filter(&(&1[:domain] == domain))
  end

  @doc """
  Find an available agent for a domain.

  Returns the first connected agent in the domain, or nil if none available.
  """
  @spec find_available_agent_for_domain(String.t()) :: map() | nil
  def find_available_agent_for_domain(domain) do
    find_agents_for_domain(domain)
    |> Enum.find(&(&1[:status] == :connected))
  end

  @doc """
  Find agents connected to a specific gateway node.
  """
  @spec find_agents_for_gateway(node()) :: [map()]
  def find_agents_for_gateway(gateway_node) do
    find_agents()
    |> Enum.filter(&(&1[:gateway_node] == gateway_node))
  end

  @doc """
  Find agents with specific capabilities.
  """
  @spec find_agents_with_capability(atom()) :: [map()]
  def find_agents_with_capability(capability) do
    find_agents()
    |> Enum.filter(fn agent ->
      capability in Map.get(agent, :capabilities, [])
    end)
  end

  @doc """
  Get gRPC connection details for an agent.

  Returns `{:ok, {host, port}}` if agent is registered with gRPC details,
  or `{:error, :not_found}` if agent is not registered or has no gRPC address.
  """
  @spec get_grpc_address(String.t()) ::
          {:ok, {String.t(), pos_integer()}} | {:error, :not_found | :no_grpc_address}
  def get_grpc_address(agent_id) when is_binary(agent_id) do
    case lookup(agent_id) do
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
  Find all agents with gRPC addresses available.

  Used by gateways to discover agents they can communicate with.
  """
  @spec find_agents_with_grpc() :: [map()]
  def find_agents_with_grpc do
    find_agents()
    |> Enum.filter(fn agent ->
      is_binary(agent[:grpc_host]) and is_integer(agent[:grpc_port]) and agent[:grpc_port] > 0
    end)
  end

  @doc """
  Get all registered agents.

  Queries the database as source of truth for admin views.
  """
  @spec all_agents() :: [map()]
  def all_agents do
    # For admin, query Ash for all agents in database
    # DB connection's search_path determines the schema
    actor = SystemActor.system(:agent_registry)

    case Ash.read(ServiceRadar.Infrastructure.Agent, actor: actor) do
      {:ok, agents} -> agents
      _ -> []
    end
  end

  @doc """
  Count of registered agents.
  """
  @spec count() :: non_neg_integer()
  def count do
    ProcessRegistry.count_by_type(:agent)
  end
end
