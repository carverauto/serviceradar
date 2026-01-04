defmodule ServiceRadar.RegistrySyncTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  @tenant_id "tenant-sync"
  @partition_id "partition-sync"
  @domain "sync-domain"

  setup_all do
    ensure_distribution!()
    ensure_apps_started()
    start_registry(ServiceRadar.GatewayRegistry)
    start_registry(ServiceRadar.AgentRegistry)

    {:ok, peer, peer_node} = start_peer(:registry_peer)
    sync_code_paths(peer_node)
    ensure_apps_started_remote(peer_node)
    start_registry_remote(peer_node, ServiceRadar.GatewayRegistry)
    start_registry_remote(peer_node, ServiceRadar.AgentRegistry)
    ensure_connected(peer_node)
    ensure_members(peer_node)

    on_exit(fn -> stop_peer(peer) end)

    {:ok, peer_node: peer_node}
  end

  test "gateway registry syncs across nodes", %{peer_node: peer_node} do
    key = {@tenant_id, @partition_id, Node.self()}

    metadata = %{
      tenant_id: @tenant_id,
      partition_id: @partition_id,
      domain: @domain,
      capabilities: [:icmp, :tcp],
      node: Node.self(),
      status: :available,
      registered_at: DateTime.utc_now(),
      last_heartbeat: DateTime.utc_now()
    }

    assert {:ok, _pid} = ServiceRadar.GatewayRegistry.register(key, metadata)

    assert eventually(fn ->
             match?(
               [{_pid, _meta} | _],
               lookup_remote(ServiceRadar.GatewayRegistry, key, peer_node)
             )
           end)
  end

  test "agent registry syncs across nodes", %{peer_node: peer_node} do
    agent_id = "agent-sync-#{System.unique_integer([:positive])}"
    key = {@tenant_id, @partition_id, agent_id}

    metadata = %{
      tenant_id: @tenant_id,
      partition_id: @partition_id,
      agent_id: agent_id,
      poller_node: Node.self(),
      capabilities: [:grpc_checker],
      status: :connected,
      connected_at: DateTime.utc_now(),
      last_heartbeat: DateTime.utc_now()
    }

    assert {:ok, _pid} = ServiceRadar.AgentRegistry.register(key, metadata)

    assert eventually(fn ->
             match?(
               [{_pid, _meta} | _],
               lookup_remote(ServiceRadar.AgentRegistry, key, peer_node)
             )
           end)
  end

  defp ensure_distribution! do
    unless Node.alive?() do
      case System.cmd("epmd", ["-daemon"]) do
        {_, 0} -> :ok
        {output, code} -> raise "Failed to start epmd (#{code}): #{output}"
      end

      {:ok, _} = :net_kernel.start([:registry_sync, :shortnames])
    end

    Node.set_cookie(:serviceradar_registry_sync)
  end

  defp ensure_apps_started do
    {:ok, _} = Application.ensure_all_started(:horde)
    {:ok, _} = Application.ensure_all_started(:telemetry)
  end

  defp start_registry(registry) do
    case registry.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp start_registry_remote(node, registry) do
    case :rpc.call(node, ServiceRadar.RegistrySyncHelper, :start_registry_unlinked, [registry]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      other -> raise "Failed to start #{registry} on #{node}: #{inspect(other)}"
    end
  end

  defp start_peer(name) do
    :peer.start_link(%{
      name: name,
      args: [~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
    })
  end

  defp stop_peer(peer) do
    try do
      if Process.alive?(peer) do
        :peer.stop(peer)
      else
        :ok
      end
    catch
      :exit, _ -> :ok
    end
  end

  defp sync_code_paths(node) do
    :rpc.call(node, :code, :add_paths, [:code.get_path()])
  end

  defp ensure_apps_started_remote(node) do
    case :rpc.call(node, Application, :ensure_all_started, [:horde]) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Failed to start :horde on #{node}: #{inspect(reason)}"
    end

    case :rpc.call(node, Application, :ensure_all_started, [:telemetry]) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Failed to start :telemetry on #{node}: #{inspect(reason)}"
    end
  end

  defp ensure_connected(peer_node) do
    Node.connect(peer_node)
    :rpc.call(peer_node, Node, :connect, [node()])

    unless eventually(fn -> peer_node in Node.list() end) do
      raise "Failed to connect to peer node #{peer_node}"
    end
  end

  defp ensure_members(peer_node) do
    gateway_members = [
      {ServiceRadar.GatewayRegistry, node()},
      {ServiceRadar.GatewayRegistry, peer_node}
    ]

    agent_members = [
      {ServiceRadar.AgentRegistry, node()},
      {ServiceRadar.AgentRegistry, peer_node}
    ]

    :ok = Horde.Cluster.set_members(ServiceRadar.GatewayRegistry, gateway_members)
    :ok = Horde.Cluster.set_members(ServiceRadar.AgentRegistry, agent_members)
  end

  defp lookup_remote(registry, key, node) do
    :rpc.call(node, Horde.Registry, :lookup, [registry, key])
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    case fun.() do
      true ->
        true

      false ->
        Process.sleep(200)
        eventually(fun, attempts - 1)
    end
  end
end
