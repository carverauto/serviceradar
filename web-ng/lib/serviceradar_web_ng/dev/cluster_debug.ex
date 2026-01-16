defmodule ServiceRadarWebNG.Dev.ClusterDebug do
  @moduledoc """
  Cluster debugging utilities for development.

  This is a single-tenant instance - each deployment serves ONE tenant.
  The tenant is implicit from PostgreSQL search_path.

  ## Usage in IEx

      iex> ServiceRadarWebNG.Dev.ClusterDebug.status()
      iex> ServiceRadarWebNG.Dev.ClusterDebug.registry_state()
  """

  require Logger

  @doc """
  Print complete cluster status.
  """
  def status do
    IO.puts("\n=== Cluster Status ===")
    IO.puts("Current node: #{Node.self()}")
    IO.puts("Connected nodes: #{inspect(Node.list())}")
    IO.puts("Node count: #{length(Node.list()) + 1}")

    IO.puts("\n=== Registry Contents ===")
    registry_state()

    :ok
  end

  @doc """
  Show current registry contents (queries database via Ash).
  """
  def registry_state do
    try do
      gateway_count = ServiceRadar.GatewayRegistry.count()
      gateways = ServiceRadar.GatewayRegistry.all_gateways()
      IO.puts("\nGateways (db_count=#{length(gateways)}, registry_count=#{gateway_count}):")

      for gateway <- Enum.take(gateways, 10) do
        IO.puts("  - #{gateway.id} status=#{gateway.status}")
      end

      if length(gateways) > 10, do: IO.puts("  ... and #{length(gateways) - 10} more")
    rescue
      e -> IO.puts("Gateway error: #{inspect(e)}")
    end

    try do
      agent_count = ServiceRadar.AgentRegistry.count()
      agents = ServiceRadar.AgentRegistry.all_agents()
      IO.puts("\nAgents (db_count=#{length(agents)}, registry_count=#{agent_count}):")

      for agent <- Enum.take(agents, 10) do
        IO.puts("  - #{agent.uid} status=#{agent.status}")
      end

      if length(agents) > 10, do: IO.puts("  ... and #{length(agents) - 10} more")
    rescue
      e -> IO.puts("Agent error: #{inspect(e)}")
    end

    :ok
  end

  @doc """
  Query a specific node's registry directly via RPC.
  """
  def remote_registry_count(node) do
    IO.puts("Querying #{node}...")

    gateway_count = :rpc.call(node, ServiceRadar.GatewayRegistry, :count, [])
    agent_count = :rpc.call(node, ServiceRadar.AgentRegistry, :count, [])

    IO.puts("  GatewayRegistry count: #{inspect(gateway_count)}")
    IO.puts("  AgentRegistry count: #{inspect(agent_count)}")

    {gateway_count, agent_count}
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
