defmodule ServiceRadarWebNG.Dev.MockCluster do
  @moduledoc """
  Development helper to register mock pollers and agents in the Horde registries.

  This module is only for local development and testing. It simulates having
  a distributed cluster by registering fake pollers and agents that would
  normally be registered by separate serviceradar_poller and serviceradar_agent
  applications.

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
    # Get all pollers and agents registered by this module
    pollers = ServiceRadar.PollerRegistry.all_pollers()
    agents = ServiceRadar.AgentRegistry.all_agents()

    for poller <- pollers do
      key = Map.get(poller, :key)
      if key, do: ServiceRadar.PollerRegistry.unregister(key)
    end

    for agent <- agents do
      key = Map.get(agent, :key)
      if key, do: ServiceRadar.AgentRegistry.unregister(key)
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

    for poller <- state.pollers do
      ServiceRadar.PollerRegistry.unregister(poller.key)
    end

    for agent <- state.agents do
      ServiceRadar.AgentRegistry.unregister(agent.key)
    end

    :ok
  end

  # Private functions

  defp register_mock_pollers(count) do
    partitions = ["production", "staging", "edge-site-1"]
    domains = ["us-west", "us-east", "eu-west"]

    for i <- 1..count do
      partition = Enum.at(partitions, rem(i - 1, length(partitions)))
      domain = Enum.at(domains, rem(i - 1, length(domains)))
      poller_id = "dev-poller-#{i}"
      key = {partition, poller_id}

      metadata = %{
        key: key,
        poller_id: poller_id,
        partition_id: partition,
        domain: domain,
        capabilities: [:icmp, :tcp, :grpc],
        node: Node.self(),
        status: :available,
        agent_count: rem(i, 5) + 1,
        registered_at: DateTime.utc_now(),
        last_heartbeat: DateTime.utc_now()
      }

      case ServiceRadar.PollerRegistry.register(key, metadata) do
        {:ok, _pid} ->
          Logger.debug("[MockCluster] Registered poller: #{poller_id}")

          Phoenix.PubSub.broadcast(
            ServiceRadar.PubSub,
            "poller:registrations",
            {:poller_registered, metadata}
          )

          metadata

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
    partitions = ["production", "staging", "edge-site-1"]

    capability_sets = [
      [:snmp, :wmi],
      [:disk, :process],
      [:snmp, :icmp, :tcp],
      [:http, :dns],
      [:mysql, :postgres]
    ]

    statuses = [:available, :available, :available, :busy, :available]

    for i <- 1..count do
      partition = Enum.at(partitions, rem(i - 1, length(partitions)))
      capabilities = Enum.at(capability_sets, rem(i - 1, length(capability_sets)))
      status = Enum.at(statuses, rem(i - 1, length(statuses)))
      agent_id = "dev-agent-#{i}"
      poller_id = "dev-poller-#{rem(i - 1, 2) + 1}"
      key = {partition, agent_id}

      metadata = %{
        key: key,
        agent_id: agent_id,
        partition_id: partition,
        poller_id: poller_id,
        poller_node: Node.self(),
        capabilities: capabilities,
        node: Node.self(),
        status: status,
        connected_at: DateTime.add(DateTime.utc_now(), -:rand.uniform(3600), :second),
        registered_at: DateTime.utc_now(),
        last_heartbeat: DateTime.utc_now()
      }

      case ServiceRadar.AgentRegistry.register(key, metadata) do
        {:ok, _pid} ->
          Logger.debug("[MockCluster] Registered agent: #{agent_id}")

          Phoenix.PubSub.broadcast(
            ServiceRadar.PubSub,
            "agent:registrations",
            {:agent_registered, metadata}
          )

          metadata

        {:error, reason} ->
          Logger.warning("[MockCluster] Failed to register agent #{agent_id}: #{inspect(reason)}")
          nil
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  defp update_heartbeats(pollers, agents) do
    now = DateTime.utc_now()

    for poller <- pollers do
      ServiceRadar.PollerRegistry.update_value(poller.key, fn meta ->
        %{meta | last_heartbeat: now}
      end)
    end

    for agent <- agents do
      ServiceRadar.AgentRegistry.update_value(agent.key, fn meta ->
        %{meta | last_heartbeat: now}
      end)
    end
  end

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
  end
end
