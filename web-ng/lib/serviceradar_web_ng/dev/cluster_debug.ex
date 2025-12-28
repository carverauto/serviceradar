defmodule ServiceRadarWebNG.Dev.ClusterDebug do
  @moduledoc """
  Cluster debugging utilities for understanding Horde registry sync issues.

  ## Usage in IEx

      iex> ServiceRadarWebNG.Dev.ClusterDebug.status()
      iex> ServiceRadarWebNG.Dev.ClusterDebug.horde_members()
      iex> ServiceRadarWebNG.Dev.ClusterDebug.registry_state()
  """

  require Logger

  @doc """
  Print complete cluster and Horde status.
  """
  def status do
    IO.puts("\n=== Cluster Status ===")
    IO.puts("Current node: #{Node.self()}")
    IO.puts("Connected nodes: #{inspect(Node.list())}")
    IO.puts("Node count: #{length(Node.list()) + 1}")

    IO.puts("\n=== Horde Registry Status ===")
    horde_members()

    IO.puts("\n=== Registry Contents ===")
    registry_state()

    :ok
  end

  @doc """
  Show Horde registry members for PollerRegistry and AgentRegistry.
  """
  def horde_members do
    try do
      poller_members = Horde.Cluster.members(ServiceRadar.PollerRegistry)
      IO.puts("PollerRegistry members: #{inspect(poller_members)}")
    rescue
      e -> IO.puts("PollerRegistry error: #{inspect(e)}")
    end

    try do
      agent_members = Horde.Cluster.members(ServiceRadar.AgentRegistry)
      IO.puts("AgentRegistry members: #{inspect(agent_members)}")
    rescue
      e -> IO.puts("AgentRegistry error: #{inspect(e)}")
    end

    :ok
  end

  @doc """
  Show current registry contents.
  """
  def registry_state do
    try do
      poller_count = ServiceRadar.PollerRegistry.count()
      pollers = ServiceRadar.PollerRegistry.all_pollers()
      IO.puts("\nPollers (count=#{poller_count}, results=#{length(pollers)}):")

      for poller <- pollers do
        IO.puts("  - #{inspect(poller[:key])} on #{inspect(poller[:node])}")
      end
    rescue
      e -> IO.puts("Poller error: #{inspect(e)}")
    end

    try do
      agent_count = ServiceRadar.AgentRegistry.count()
      agents = ServiceRadar.AgentRegistry.all_agents()
      IO.puts("\nAgents (count=#{agent_count}, results=#{length(agents)}):")

      for agent <- agents do
        IO.puts("  - #{inspect(agent[:key])} on #{inspect(agent[:node])}")
      end
    rescue
      e -> IO.puts("Agent error: #{inspect(e)}")
    end

    :ok
  end

  @doc """
  Force Horde to sync with other cluster members.
  """
  def force_sync do
    nodes = Node.list()

    IO.puts("Syncing with #{length(nodes)} nodes...")

    # Get current Horde members
    poller_members =
      for node <- [Node.self() | nodes] do
        {ServiceRadar.PollerRegistry, node}
      end

    agent_members =
      for node <- [Node.self() | nodes] do
        {ServiceRadar.AgentRegistry, node}
      end

    IO.puts("Setting PollerRegistry members: #{inspect(poller_members)}")
    Horde.Cluster.set_members(ServiceRadar.PollerRegistry, poller_members)

    IO.puts("Setting AgentRegistry members: #{inspect(agent_members)}")
    Horde.Cluster.set_members(ServiceRadar.AgentRegistry, agent_members)

    # Wait a moment for sync
    Process.sleep(1000)

    IO.puts("\nAfter sync:")
    registry_state()

    :ok
  end

  @doc """
  Query a specific node's registry directly via RPC.
  """
  def remote_registry_count(node) do
    IO.puts("Querying #{node}...")

    poller_count = :rpc.call(node, ServiceRadar.PollerRegistry, :count, [])
    agent_count = :rpc.call(node, ServiceRadar.AgentRegistry, :count, [])

    IO.puts("  PollerRegistry count: #{inspect(poller_count)}")
    IO.puts("  AgentRegistry count: #{inspect(agent_count)}")

    {poller_count, agent_count}
  end

  @doc """
  Query all nodes' registries.
  """
  def all_nodes_registry_count do
    nodes = [Node.self() | Node.list()]

    for node <- nodes do
      {node, remote_registry_count(node)}
    end
  end
end
