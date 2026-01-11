defmodule ServiceRadarWebNG.Dev.MockCluster do
  @moduledoc """
  Development helper to register mock gateways and agents in the Horde registries.

  This module is only for local development and testing. It simulates having
  a distributed cluster by registering fake gateways and agents that would
  normally be registered by serviceradar_gateway (Elixir) and Go agents
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
  Manually set up mock cluster data (gateways and agents).
  """
  def setup(opts \\ []) do
    gateway_count = Keyword.get(opts, :gateways, 2)
    agent_count = Keyword.get(opts, :agents, 3)

    register_mock_gateways(gateway_count)
    register_mock_agents(agent_count)

    :ok
  end

  @doc """
  Clear all mock data from the registries.
  """
  def teardown do
    tenant_id = @dev_tenant_id

    # Get all gateways and agents registered for the dev tenant
    gateways = ServiceRadar.GatewayRegistry.find_gateways_for_tenant(tenant_id)
    agents = ServiceRadar.AgentRegistry.find_agents_for_tenant(tenant_id)

    for gateway <- gateways do
      gateway_id = Map.get(gateway, :gateway_id)
      if gateway_id, do: ServiceRadar.GatewayRegistry.unregister_gateway(tenant_id, gateway_id)
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
    gateway_count = Keyword.get(opts, :gateways, 2)
    agent_count = Keyword.get(opts, :agents, 3)

    Logger.info("[MockCluster] Starting with #{gateway_count} gateways and #{agent_count} agents")

    # Register mock data
    gateways = register_mock_gateways(gateway_count)
    agents = register_mock_agents(agent_count)

    # Schedule heartbeat updates
    schedule_heartbeat()

    {:ok, %{gateways: gateways, agents: agents}}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    # Update heartbeats for all registered mocks
    update_heartbeats(state.gateways, state.agents)
    schedule_heartbeat()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Logger.info("[MockCluster] Shutting down, unregistering mock data")
    tenant_id = @dev_tenant_id

    for gateway <- state.gateways do
      ServiceRadar.GatewayRegistry.unregister_gateway(tenant_id, gateway.gateway_id)
    end

    for agent <- state.agents do
      ServiceRadar.AgentRegistry.unregister_agent(tenant_id, agent.agent_id)
    end

    :ok
  end

  # Private functions

  defp register_mock_gateways(count) do
    tenant_id = @dev_tenant_id
    partitions = ["production", "staging", "edge-site-1"]
    domains = ["us-west", "us-east", "eu-west"]

    for i <- 1..count do
      partition = Enum.at(partitions, rem(i - 1, length(partitions)))
      domain = Enum.at(domains, rem(i - 1, length(domains)))
      gateway_id = "dev-gateway-#{i}"

      gateway_info = %{
        partition_id: partition,
        domain: domain,
        status: :available
      }

      case ServiceRadar.GatewayRegistry.register_gateway(tenant_id, gateway_id, gateway_info) do
        {:ok, _pid} ->
          Logger.debug("[MockCluster] Registered gateway: #{gateway_id}")

          %{
            gateway_id: gateway_id,
            tenant_id: tenant_id,
            partition_id: partition,
            domain: domain,
            status: :available
          }

        {:error, reason} ->
          Logger.warning(
            "[MockCluster] Failed to register gateway #{gateway_id}: #{inspect(reason)}"
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

  defp update_heartbeats(gateways, agents) do
    tenant_id = @dev_tenant_id

    for gateway <- gateways do
      ServiceRadar.GatewayRegistry.heartbeat(tenant_id, gateway.gateway_id)
    end

    for agent <- agents do
      ServiceRadar.AgentRegistry.heartbeat(tenant_id, agent.agent_id)
    end
  end

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
  end
end
