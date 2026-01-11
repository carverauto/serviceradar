defmodule ServiceRadarWebNG.Dev.ClusterDebug do
  @moduledoc """
  Cluster debugging utilities for understanding Horde registry sync issues.

  ## Architecture Note

  ServiceRadar uses per-tenant Horde registries managed by TenantRegistry.
  Each tenant gets their own isolated registry, which syncs automatically
  via `members: :auto` configuration.

  ## Usage in IEx

      iex> ServiceRadarWebNG.Dev.ClusterDebug.status()
      iex> ServiceRadarWebNG.Dev.ClusterDebug.tenant_registries()
      iex> ServiceRadarWebNG.Dev.ClusterDebug.registry_state()
  """

  alias ServiceRadar.Cluster.TenantRegistry

  require Logger

  @doc """
  Print complete cluster and Horde status.
  """
  def status do
    IO.puts("\n=== Cluster Status ===")
    IO.puts("Current node: #{Node.self()}")
    IO.puts("Connected nodes: #{inspect(Node.list())}")
    IO.puts("Node count: #{length(Node.list()) + 1}")

    IO.puts("\n=== Tenant Registries ===")
    tenant_registries()

    IO.puts("\n=== Registry Contents ===")
    registry_state()

    :ok
  end

  @doc """
  Show per-tenant Horde registries managed by TenantRegistry.
  """
  def tenant_registries do
    try do
      registries = TenantRegistry.list_registries()
      IO.puts("Active tenant registries: #{length(registries)}")

      for {name, pid} <- registries do
        IO.puts("  - #{name} (#{inspect(pid)})")
      end
    rescue
      e -> IO.puts("TenantRegistry error: #{inspect(e)}")
    end

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
  Force Horde to sync with other cluster members.

  Note: Per-tenant registries use `members: :auto` and sync automatically.
  This function is kept for compatibility but does nothing with TenantRegistry.
  """
  def force_sync do
    IO.puts("Per-tenant registries use members: :auto and sync automatically.")
    IO.puts("No manual sync needed with TenantRegistry architecture.")
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

  @doc """
  Show registered gateways for a specific tenant.
  """
  def gateways_for_tenant(tenant_id) do
    gateways = ServiceRadar.GatewayRegistry.find_gateways_for_tenant(tenant_id)
    IO.puts("Gateways for tenant #{tenant_id}: #{length(gateways)}")

    for gateway <- gateways do
      IO.puts("  - #{gateway[:gateway_id]} status=#{gateway[:status]} node=#{gateway[:node]}")
    end

    :ok
  end

  @doc """
  Show registered agents for a specific tenant.
  """
  def agents_for_tenant(tenant_id) do
    agents = ServiceRadar.AgentRegistry.find_agents_for_tenant(tenant_id)
    IO.puts("Agents for tenant #{tenant_id}: #{length(agents)}")

    for agent <- agents do
      IO.puts("  - #{agent[:agent_id]} status=#{agent[:status]} node=#{agent[:node]}")
    end

    :ok
  end
end
