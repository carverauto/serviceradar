defmodule ServiceRadarWebNG.Dev.MockCluster do
  @moduledoc """
  Development helper to register mock pollers and agents in the Horde registries.

  This module is only for local development and testing. It simulates having
  a distributed cluster by registering fake pollers and agents that would
  normally be registered by serviceradar_poller (Elixir) and Go agents
  connecting via gRPC.

  ## Usage

  In iex:

      iex> ServiceRadarWebNG.Dev.MockCluster.setup()
      :ok

  Or start as a supervised process:

      # In your dev.exs:
      config :serviceradar_web_ng, mock_cluster: true

  """

  use GenServer

  require Logger

  @heartbeat_interval :timer.seconds(30)
  # Default dev tenant ID for mock cluster
  @dev_tenant_id "00000000-0000-0000-0000-000000000001"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually set up mock cluster data (pollers and agents).
  """
  def setup(opts \\ []) do
    poller_count = Keyword.get(opts, :pollers, 2)
    agent_count = Keyword.get(opts, :agents, 3)

    register_mock_pollers(poller_count)
    register_mock_agents(agent_count)

    :ok
  end

  @doc """
  Clear all mock data from the registries.
  """
  def teardown do
    tenant_id = @dev_tenant_id

    # Get all pollers and agents registered for the dev tenant
    pollers = ServiceRadar.PollerRegistry.find_pollers_for_tenant(tenant_id)
    agents = ServiceRadar.AgentRegistry.find_agents_for_tenant(tenant_id)

    for poller <- pollers do
      poller_id = Map.get(poller, :poller_id)
      if poller_id, do: ServiceRadar.PollerRegistry.unregister_poller(tenant_id, poller_id)
    end

    for agent <- agents do
      agent_id = Map.get(agent, :agent_id)
      if agent_id, do: ServiceRadar.AgentRegistry.unregister_agent(tenant_id, agent_id)
    end

    :ok
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    poller_count = Keyword.get(opts, :pollers, 2)
    agent_count = Keyword.get(opts, :agents, 3)

    Logger.info("[MockCluster] Starting with #{poller_count} pollers and #{agent_count} agents")

    # Register mock data
    pollers = register_mock_pollers(poller_count)
    agents = register_mock_agents(agent_count)

    # Schedule heartbeat updates
    schedule_heartbeat()

    {:ok, %{pollers: pollers, agents: agents}}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    # Update heartbeats for all registered mocks
    update_heartbeats(state.pollers, state.agents)
    schedule_heartbeat()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Logger.info("[MockCluster] Shutting down, unregistering mock data")
    tenant_id = @dev_tenant_id

    for poller <- state.pollers do
      ServiceRadar.PollerRegistry.unregister_poller(tenant_id, poller.poller_id)
    end

    for agent <- state.agents do
      ServiceRadar.AgentRegistry.unregister_agent(tenant_id, agent.agent_id)
    end

    :ok
  end

  # Private functions

  defp register_mock_pollers(count) do
    tenant_id = @dev_tenant_id
    partitions = ["production", "staging", "edge-site-1"]
    domains = ["us-west", "us-east", "eu-west"]

    for i <- 1..count do
      partition = Enum.at(partitions, rem(i - 1, length(partitions)))
      domain = Enum.at(domains, rem(i - 1, length(domains)))
      poller_id = "dev-poller-#{i}"

      poller_info = %{
        partition_id: partition,
        domain: domain,
        status: :available
      }

      case ServiceRadar.PollerRegistry.register_poller(tenant_id, poller_id, poller_info) do
        {:ok, _pid} ->
          Logger.debug("[MockCluster] Registered poller: #{poller_id}")

          %{
            poller_id: poller_id,
            tenant_id: tenant_id,
            partition_id: partition,
            domain: domain,
            status: :available
          }

        {:error, reason} ->
          Logger.warning(
            "[MockCluster] Failed to register poller #{poller_id}: #{inspect(reason)}"
          )

          nil
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  defp register_mock_agents(count) do
    tenant_id = @dev_tenant_id
    partitions = ["production", "staging", "edge-site-1"]

    capability_sets = [
      [:snmp, :wmi],
      [:disk, :process],
      [:snmp, :icmp, :tcp],
      [:http, :dns],
      [:mysql, :postgres]
    ]

    statuses = [:connected, :connected, :connected, :degraded, :connected]

    for i <- 1..count do
      partition = Enum.at(partitions, rem(i - 1, length(partitions)))
      capabilities = Enum.at(capability_sets, rem(i - 1, length(capability_sets)))
      status = Enum.at(statuses, rem(i - 1, length(statuses)))
      agent_id = "dev-agent-#{i}"

      agent_info = %{
        partition_id: partition,
        capabilities: capabilities,
        status: status
      }

      case ServiceRadar.AgentRegistry.register_agent(tenant_id, agent_id, agent_info) do
        {:ok, _pid} ->
          Logger.debug("[MockCluster] Registered agent: #{agent_id}")

          %{
            agent_id: agent_id,
            tenant_id: tenant_id,
            partition_id: partition,
            capabilities: capabilities,
            status: status
          }

        {:error, reason} ->
          Logger.warning("[MockCluster] Failed to register agent #{agent_id}: #{inspect(reason)}")
          nil
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  defp update_heartbeats(pollers, agents) do
    tenant_id = @dev_tenant_id

    for poller <- pollers do
      ServiceRadar.PollerRegistry.heartbeat(tenant_id, poller.poller_id)
    end

    for agent <- agents do
      ServiceRadar.AgentRegistry.heartbeat(tenant_id, agent.agent_id)
    end
  end

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
  end
end
