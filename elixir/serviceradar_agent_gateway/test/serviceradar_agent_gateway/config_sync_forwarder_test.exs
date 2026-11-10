defmodule ServiceRadarAgentGateway.ConfigSyncForwarderTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadarAgentGateway.ClusterProcessLocator
  alias ServiceRadarAgentGateway.ConfigSyncForwarder

  setup do
    test_pid = self()

    Application.put_env(:serviceradar_agent_gateway, :config_sync_rpc, fn function, args ->
      send(test_pid, {:config_sync, function, args})
      :ok
    end)

    on_exit(fn -> Application.delete_env(:serviceradar_agent_gateway, :config_sync_rpc) end)

    :ok
  end

  test "sectioned ack forwards normalized per-section statuses" do
    ack = %Monitoring.ConfigAck{
      config_version: "v2",
      timestamp: 1_782_000_000,
      section_statuses: [
        %Monitoring.ConfigSectionStatus{section: "bumblebee", disposition: "success"},
        %Monitoring.ConfigSectionStatus{
          section: "visibility",
          disposition: "permanent_failure",
          error: "merge netprobe add-on config: cannot unmarshal string",
          since: 1_781_900_000
        }
      ]
    }

    assert :ok = ConfigSyncForwarder.record_config_ack("agent-1", ack)

    assert_receive {:config_sync, :record_config_ack, ["agent-1", attrs]}
    assert attrs.config_version == "v2"
    assert %DateTime{} = attrs.acked_at

    assert [
             %{"section" => "bumblebee", "disposition" => "success"},
             %{"section" => "visibility", "disposition" => "permanent_failure"} = failing
           ] = attrs.section_statuses

    assert failing["error"] =~ "cannot unmarshal string"
    assert failing["since"] =~ "2026"
  end

  test "legacy ack (no section statuses) forwards nil section detail" do
    ack = %Monitoring.ConfigAck{config_version: "v1", timestamp: 1_782_000_000}

    assert :ok = ConfigSyncForwarder.record_config_ack("agent-legacy", ack)

    assert_receive {:config_sync, :record_config_ack, ["agent-legacy", attrs]}
    assert attrs.config_version == "v1"
    assert attrs.section_statuses == nil
  end

  test "reported committed version forwards as a whole-version ack" do
    assert :ok = ConfigSyncForwarder.record_reported_version("agent-2", "v3")

    assert_receive {:config_sync, :record_config_ack, ["agent-2", attrs]}
    assert attrs.config_version == "v3"
    assert attrs.section_statuses == nil
  end

  test "config push forwards version and timestamp" do
    assert :ok = ConfigSyncForwarder.record_config_push("agent-3", "v4")

    assert_receive {:config_sync, :record_config_push, ["agent-3", attrs]}
    assert attrs.config_version == "v4"
    assert %DateTime{} = attrs.pushed_at
  end

  test "rpc errors are surfaced, not raised" do
    Application.put_env(:serviceradar_agent_gateway, :config_sync_rpc, fn _function, _args ->
      {:error, :core_unavailable}
    end)

    ack = %Monitoring.ConfigAck{config_version: "v1", timestamp: 0}
    assert {:error, :core_unavailable} = ConfigSyncForwarder.record_config_ack("agent-4", ack)
  end

  test "caller facing an older core node neither crashes nor logs an error, and succeeds once a capable node exists" do
    Application.delete_env(:serviceradar_agent_gateway, :config_sync_rpc)
    ensure_distribution_started!()

    if !Process.whereis(ClusterProcessLocator) do
      start_supervised!(ClusterProcessLocator)
    end

    basename = "rolling_rpc_core_#{System.unique_integer([:positive])}"
    previous_basename = Application.get_env(:serviceradar_agent_gateway, :cluster_core_node_basename)
    previous_wait = Application.get_env(:serviceradar_core, :cluster_rpc_undef_wait_ms)
    previous_poll = Application.get_env(:serviceradar_core, :cluster_rpc_undef_poll_ms)

    Application.put_env(:serviceradar_agent_gateway, :cluster_core_node_basename, basename)
    Application.put_env(:serviceradar_core, :cluster_rpc_undef_wait_ms, 80)
    Application.put_env(:serviceradar_core, :cluster_rpc_undef_poll_ms, 20)

    on_exit(fn ->
      restore_env(:serviceradar_agent_gateway, :cluster_core_node_basename, previous_basename)
      restore_env(:serviceradar_core, :cluster_rpc_undef_wait_ms, previous_wait)
      restore_env(:serviceradar_core, :cluster_rpc_undef_poll_ms, previous_poll)
    end)

    _old_node =
      start_core_peer!(:old_core_peer, "#{basename}_old", """
      {:ok, pid} = Agent.start(fn -> :ok end, name: ServiceRadar.ClusterHealth)
      :persistent_term.put(:cluster_health_pid, pid)

      defmodule ServiceRadar.Edge.AgentGatewaySync do
        def record_config_ack(_agent_id, _attrs), do: :ok
      end
      """)

    assert [_] = ClusterProcessLocator.nodes(ServiceRadar.ClusterHealth)

    unready_log =
      capture_log(fn ->
        assert {:error, _reason} =
                 ConfigSyncForwarder.refresh_sweep_leases("agent-rolling-old-only", self())
      end)

    assert unready_log == ""

    Application.put_env(:serviceradar_core, :cluster_rpc_undef_wait_ms, 1_500)
    test_pid = self()

    Task.start(fn ->
      Process.sleep(60)

      start_core_peer_unsupervised(basename, test_pid, """
      defmodule ServiceRadar.Edge.AgentGatewaySync do
        def refresh_sweep_leases(agent_id, session) do
          send(:persistent_term.get(:rolling_rpc_test_owner), {:refreshed_sweep_leases, node(), agent_id, session})
          :ok
        end
      end
      """)
    end)

    on_exit(fn ->
      receive do
        {:spawned_peer, peer} ->
          try do
            :peer.stop(peer)
          catch
            _, _ -> :ok
          end
      after
        0 -> :ok
      end
    end)

    capable_log =
      capture_log(fn ->
        assert :ok = ConfigSyncForwarder.refresh_sweep_leases("agent-rolling-upgraded", self())
      end)

    assert capable_log == ""
    assert_receive {:refreshed_sweep_leases, capable_node, "agent-rolling-upgraded", ^test_pid}, 1_000
    assert Atom.to_string(capable_node) =~ "#{basename}@"
  end

  defp ensure_distribution_started! do
    if !Node.alive?() do
      {_, 0} = System.cmd("epmd", ["-daemon"])
      {:ok, _} = :net_kernel.start([:"config_sync_rpc_#{System.unique_integer([:positive])}", :shortnames])
      on_exit(fn -> :net_kernel.stop() end)
    end
  end

  defp start_core_peer!(id, peer_name, code) do
    peer =
      start_supervised!(%{
        id: id,
        start:
          {:peer, :start_link,
           [
             %{
               name: String.to_atom(peer_name),
               connection: :standard_io,
               args: [~c"+S", ~c"2", ~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
             }
           ]},
        restart: :temporary
      })

    configure_core_peer(peer, self(), code)
  end

  defp start_core_peer_unsupervised(peer_name, owner, code) do
    {:ok, peer, _node} =
      :peer.start(%{
        name: String.to_atom(peer_name),
        connection: :standard_io,
        args: [~c"+S", ~c"2", ~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
      })

    send(owner, {:spawned_peer, peer})
    configure_core_peer(peer, owner, code)
  end

  defp configure_core_peer(peer, owner, code) do
    core_node = :peer.call(peer, :erlang, :node, [])
    :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])
    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:elixir])
    :ok = :peer.call(peer, Code, :put_compiler_option, [:ignore_module_conflict, true])
    :ok = :peer.call(peer, :persistent_term, :put, [:rolling_rpc_test_owner, owner])
    :peer.call(peer, Code, :compile_string, [code])
    assert Node.connect(core_node)
    core_node
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
