defmodule ServiceRadarAgentGateway.AgentRegistryProxyTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.AgentRegistry
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadarAgentGateway.AgentRegistryProxy
  alias ServiceRadarAgentGateway.ControlStreamSession

  @retained_plugin_capability "plugin-result-retained:v1"

  setup do
    {:ok, _apps} = Application.ensure_all_started(:horde)
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    if !Process.whereis(ServiceRadar.PubSub) do
      start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
    end

    if !Process.whereis(ProcessRegistry.registry_name()) do
      Enum.each(ProcessRegistry.child_specs(), &start_supervised!/1)
    end

    if !Process.whereis(AgentRegistryProxy), do: start_supervised!(AgentRegistryProxy)

    previous_stale_after =
      Application.fetch_env(:serviceradar_agent_gateway, :agent_registry_stale_after_ms)

    on_exit(fn ->
      case previous_stale_after do
        {:ok, value} -> Application.put_env(:serviceradar_agent_gateway, :agent_registry_stale_after_ms, value)
        :error -> Application.delete_env(:serviceradar_agent_gateway, :agent_registry_stale_after_ms)
      end
    end)

    unique = System.unique_integer([:positive])
    %{agent_id: "agent-proxy-#{unique}", domain: "domain-proxy-#{unique}", partition_id: "partition-a"}
  end

  test "an agent whose control session ends is no longer connected or chosen for its domain", ctx do
    connect_agent(ctx)
    session = start_control_session!(ctx)

    assert agent_status(ctx.agent_id) == :connected
    assert %{agent_id: agent_id} = AgentRegistry.find_available_agent_for_domain(ctx.domain)
    assert agent_id == ctx.agent_id

    kill_and_await(session)

    assert_eventually(fn -> agent_status(ctx.agent_id) == :disconnected end)
    assert AgentRegistry.find_available_agent_for_domain(ctx.domain) == nil
  end

  test "an agent stays connected while another of its control sessions is live", ctx do
    connect_agent(ctx)
    first = start_control_session!(ctx)
    # One live session per principal, so the second is the same agent in another partition.
    second = start_control_session!(%{ctx | partition_id: "partition-b"})

    kill_and_await(first)
    # Serialize behind the proxy's handling of the first session's exit.
    :ok = AgentRegistryProxy.sweep_stale_agents()
    assert agent_status(ctx.agent_id) == :connected

    kill_and_await(second)
    assert_eventually(fn -> agent_status(ctx.agent_id) == :disconnected end)
  end

  test "a disconnected agent that pushes again is connected again", ctx do
    connect_agent(ctx)
    session = start_control_session!(ctx)
    kill_and_await(session)
    assert_eventually(fn -> agent_status(ctx.agent_id) == :disconnected end)

    :ok = AgentRegistryProxy.touch_agent(ctx.agent_id, %{partition_id: ctx.partition_id, status: :connected})

    assert agent_status(ctx.agent_id) == :connected
    assert %{agent_id: agent_id} = AgentRegistry.find_available_agent_for_domain(ctx.domain)
    assert agent_id == ctx.agent_id
  end

  test "an agent silent for the stale window is unregistered and its capabilities dropped", ctx do
    connect_agent(ctx, [@retained_plugin_capability])
    assert AgentRegistryProxy.delivery_capabilities(ctx.partition_id, ctx.agent_id) == [@retained_plugin_capability]

    Application.put_env(:serviceradar_agent_gateway, :agent_registry_stale_after_ms, 0)
    :ok = AgentRegistryProxy.sweep_stale_agents()

    assert AgentRegistry.lookup(ctx.agent_id) == []
    assert AgentRegistryProxy.delivery_capabilities(ctx.partition_id, ctx.agent_id) == []
  end

  test "a control session that shuts down normally marks the agent :disconnected via terminate/2", ctx do
    connect_agent(ctx)
    session = start_control_session!(ctx)

    assert agent_status(ctx.agent_id) == :connected

    stop_and_await(session)

    assert_eventually(fn -> agent_status(ctx.agent_id) == :disconnected end)
    assert AgentRegistry.find_available_agent_for_domain(ctx.domain) == nil
  end

  test "an agent with a live control session is never swept as stale", ctx do
    connect_agent(ctx, [@retained_plugin_capability])
    _session = start_control_session!(ctx, [@retained_plugin_capability])

    Application.put_env(:serviceradar_agent_gateway, :agent_registry_stale_after_ms, 0)
    :ok = AgentRegistryProxy.sweep_stale_agents()

    assert agent_status(ctx.agent_id) == :connected
    assert AgentRegistryProxy.delivery_capabilities(ctx.partition_id, ctx.agent_id) == [@retained_plugin_capability]
  end

  defp connect_agent(ctx, capabilities \\ []) do
    :ok =
      AgentRegistryProxy.touch_agent(ctx.agent_id, %{
        partition_id: ctx.partition_id,
        domain: ctx.domain,
        status: :connected,
        capabilities: capabilities
      })
  end

  defp start_control_session!(ctx, capabilities \\ []) do
    session =
      {ControlStreamSession, stream: nil}
      |> Supervisor.child_spec(id: make_ref(), restart: :temporary)
      |> start_supervised!()

    identity = %{
      component_id: ctx.agent_id,
      partition_id: ctx.partition_id,
      component_type: :agent,
      cert_fingerprint_sha256: "synthetic-fingerprint-#{ctx.agent_id}"
    }

    assert :ok = ControlStreamSession.register(session, ctx.agent_id, ctx.partition_id, capabilities, identity)
    session
  end

  defp agent_status(agent_id) do
    case AgentRegistry.lookup(agent_id) do
      [{_pid, metadata}] -> metadata.status
      [] -> :not_registered
    end
  end

  defp kill_and_await(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000
  end

  defp stop_and_await(pid) do
    ref = Process.monitor(pid)
    :ok = GenServer.stop(pid, :normal)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  defp assert_eventually(check, attempts \\ 40) do
    cond do
      check.() ->
        :ok

      attempts > 1 ->
        Process.sleep(25)
        assert_eventually(check, attempts - 1)

      true ->
        flunk("condition never held")
    end
  end
end
