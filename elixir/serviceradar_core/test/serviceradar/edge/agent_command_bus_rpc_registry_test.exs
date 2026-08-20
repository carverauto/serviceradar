defmodule ServiceRadar.Edge.AgentCommandBusRPCRegistryTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.ProcessRegistry

  @moduletag :cluster

  test "a web node without a local Horde registry discovers mapper sessions over registry RPC" do
    ensure_distribution!()

    suffix = System.unique_integer([:positive])
    core_name = String.to_atom("serviceradar_core_rpc_#{suffix}")
    web_name = String.to_atom("serviceradar_web_ng_rpc_#{suffix}")

    {:ok, core_peer, core_node} = start_peer(core_name)
    {:ok, web_peer, web_node} = start_peer(web_name)

    on_exit(fn ->
      stop_peer(web_peer)
      stop_peer(core_peer)
    end)

    sync_code_paths(core_node)
    sync_code_paths(web_node)
    start_registry(core_node)

    :ok =
      :erpc.call(web_node, Application, :put_env, [
        :serviceradar_core,
        :core_node_basename,
        Atom.to_string(core_name)
      ])

    assert true == :erpc.call(web_node, Node, :connect, [core_node])
    assert eventually(fn -> core_node in :erpc.call(web_node, Node, :list, [:visible]) end)
    refute :erpc.call(web_node, ProcessRegistry, :registry_present?, [])

    agent_id = "rpc-mapper-#{suffix}"

    metadata = %{
      agent_id: agent_id,
      partition_id: "default",
      gateway_node: Atom.to_string(core_node),
      capabilities: ["mapper"]
    }

    name =
      ProcessRegistry.via(
        {:agent_control, "default", agent_id, core_node},
        metadata
      )

    assert {:ok, session_pid} =
             :erpc.call(core_node, Agent, :start, [Map, :new, [], [name: name]])

    assert eventually(fn ->
             web_node
             |> :erpc.call(AgentCommandBus, :list_online_agents, [])
             |> Enum.any?(fn session ->
               session.agent_id == agent_id and session.partition_id == "default" and
                 session.pid == session_pid and "mapper" in session.capabilities and
                 session.canonical_principal?
             end)
           end)
  end

  defp ensure_distribution! do
    if !Node.alive?() do
      case System.cmd("epmd", ["-daemon"]) do
        {_output, 0} -> :ok
        {output, code} -> flunk("failed to start epmd (#{code}): #{output}")
      end

      assert {:ok, _pid} = :net_kernel.start([:agent_command_bus_rpc, :shortnames])
    end

    Node.set_cookie(:agent_command_bus_rpc_test)
  end

  defp start_peer(name) do
    :peer.start_link(%{
      name: name,
      args: [~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
    })
  end

  defp sync_code_paths(node) do
    assert :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])
  end

  defp start_registry(node) do
    assert {:ok, _apps} = :erpc.call(node, Application, :ensure_all_started, [:horde])

    assert {:ok, _pid} =
             :erpc.call(
               node,
               ServiceRadar.RegistrySyncHelper,
               :start_registry_unlinked,
               [ProcessRegistry]
             )
  end

  defp stop_peer(peer) do
    if Process.alive?(peer), do: :peer.stop(peer)
  catch
    :exit, _reason -> :ok
  end

  defp eventually(fun, attempts \\ 40)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(50)
      eventually(fun, attempts - 1)
    end
  end
end
