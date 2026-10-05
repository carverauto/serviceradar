defmodule ServiceRadar.Edge.GatewayProcessAgentSelectionTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.AgentRegistry
  alias ServiceRadar.Edge.GatewayProcess
  alias ServiceRadar.ProcessRegistry

  @moduletag :db_free

  setup do
    {:ok, _apps} = Application.ensure_all_started(:horde)
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    if !Process.whereis(ServiceRadar.PubSub) do
      start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
    end

    if !Process.whereis(ProcessRegistry.registry_name()) do
      Enum.each(ProcessRegistry.child_specs(), &start_supervised!/1)
    end

    if !Process.whereis(ServiceRadar.LocalRegistry) do
      start_supervised!({Registry, keys: :unique, name: ServiceRadar.LocalRegistry})
    end

    unique = System.unique_integer([:positive])

    %{
      domain: "selection-domain-#{unique}",
      partition_id: "selection-partition-#{unique}",
      gateway_id: "selection-gateway-#{unique}",
      unique: unique
    }
  end

  test "a domain whose agents are all disconnected falls back to the partition", ctx do
    register_agent!("domain-agent-#{ctx.unique}", domain: ctx.domain, status: :disconnected)

    register_agent!("partition-agent-#{ctx.unique}",
      partition_id: ctx.partition_id,
      status: :connected
    )

    gateway = start_gateway!(ctx)

    assert {:ok, %{total: 0}} = GatewayProcess.execute_job(gateway, %{checks: []})
  end

  test "a connected agent in the domain is preferred over the partition", ctx do
    register_agent!("domain-agent-#{ctx.unique}", domain: ctx.domain, status: :connected)

    gateway = start_gateway!(ctx)

    assert {:ok, %{total: 0}} = GatewayProcess.execute_job(gateway, %{checks: []})
  end

  test "no connected agent in the domain or the partition is reported", ctx do
    register_agent!("domain-agent-#{ctx.unique}", domain: ctx.domain, status: :disconnected)

    register_agent!("partition-agent-#{ctx.unique}",
      partition_id: ctx.partition_id,
      status: :disconnected
    )

    gateway = start_gateway!(ctx)

    assert {:error, :no_available_agents} = GatewayProcess.execute_job(gateway, %{checks: []})
  end

  defp register_agent!(agent_id, attrs) do
    # Owned by the test process, so the entry goes away with it.
    {:ok, _pid} = AgentRegistry.register_agent(agent_id, Map.new(attrs))
  end

  defp start_gateway!(ctx) do
    start_supervised!(
      {GatewayProcess,
       gateway_id: ctx.gateway_id, partition_id: ctx.partition_id, domain: ctx.domain}
    )
  end
end
