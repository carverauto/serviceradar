defmodule ServiceRadarAgentGateway.CameraMediaForwarderRollingUpgradeTest do
  # Drives CameraMediaForwarder.open_relay_session/2 over real :rpc against real
  # peer BEAM nodes: an "old" core that does not export the target function (so
  # the VM itself raises :undef) and a "new" core that does. No rpc stub.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadarAgentGateway.CameraMediaForwarder

  @ingress RollingUpgradeTest.CameraMediaIngress

  setup do
    ensure_distribution_started!()

    basename = "rolling_camera_core_#{System.unique_integer([:positive])}"
    previous_basename = Application.get_env(:serviceradar_agent_gateway, :cluster_core_node_basename)
    previous_wait = Application.get_env(:serviceradar_core, :cluster_rpc_undef_wait_ms)
    previous_poll = Application.get_env(:serviceradar_core, :cluster_rpc_undef_poll_ms)

    Application.put_env(:serviceradar_agent_gateway, :cluster_core_node_basename, basename)
    Application.put_env(:serviceradar_core, :cluster_rpc_undef_wait_ms, 200)
    Application.put_env(:serviceradar_core, :cluster_rpc_undef_poll_ms, 20)

    on_exit(fn ->
      restore_env(:serviceradar_agent_gateway, :cluster_core_node_basename, previous_basename)
      restore_env(:serviceradar_core, :cluster_rpc_undef_wait_ms, previous_wait)
      restore_env(:serviceradar_core, :cluster_rpc_undef_poll_ms, previous_poll)
    end)

    old_node =
      start_core_peer!(:old_core, "#{basename}_old", """
      defmodule #{inspect(@ingress)} do
        def unrelated, do: :ok
      end
      """)

    %{basename: basename, old_node: old_node}
  end

  test "an old pinned core's :undef fails over to a capable core without logging", ctx do
    new_node =
      start_core_peer!(:new_core, ctx.basename, """
      defmodule #{inspect(@ingress)} do
        def open_relay_session(%Camera.OpenRelaySessionRequest{relay_session_id: id}) do
          {:ok, %Camera.OpenRelaySessionResponse{message: id, accepted: true}, %{host: node()}}
        end
      end
      """)

    request = %Camera.OpenRelaySessionRequest{relay_session_id: "relay-rolling-1"}

    log =
      capture_log(fn ->
        assert {:ok, %Camera.OpenRelaySessionResponse{message: "relay-rolling-1", accepted: true}, %{host: ^new_node}} =
                 CameraMediaForwarder.open_relay_session(request, opts(ctx.old_node))
      end)

    assert log == ""
  end

  test "only an old core: bounded wait, then :core_unavailable without crashing or logging", ctx do
    request = %Camera.OpenRelaySessionRequest{relay_session_id: "relay-rolling-2"}
    started = System.monotonic_time(:millisecond)

    log =
      capture_log(fn ->
        assert {:error, :core_unavailable} =
                 CameraMediaForwarder.open_relay_session(request, opts(ctx.old_node))
      end)

    elapsed = System.monotonic_time(:millisecond) - started
    assert log == ""
    assert elapsed >= 150, "expected a bounded wait for a capable peer, returned after #{elapsed}ms"
    assert elapsed < 5_000
  end

  test "a capable core that joins during the wait serves the call", ctx do
    test_pid = self()

    Task.start(fn ->
      Process.sleep(60)
      {:ok, peer, _node} = start_peer(ctx.basename)
      send(test_pid, {:spawned_peer, peer})

      configure_peer(peer, """
      defmodule #{inspect(@ingress)} do
        def open_relay_session(%Camera.OpenRelaySessionRequest{relay_session_id: id}) do
          {:ok, %Camera.OpenRelaySessionResponse{message: id, accepted: true}, %{host: node()}}
        end
      end
      """)
    end)

    on_exit(fn ->
      receive do
        {:spawned_peer, peer} -> safe_stop(peer)
      after
        0 -> :ok
      end
    end)

    Application.put_env(:serviceradar_core, :cluster_rpc_undef_wait_ms, 3_000)
    request = %Camera.OpenRelaySessionRequest{relay_session_id: "relay-rolling-3"}

    log =
      capture_log(fn ->
        assert {:ok, %Camera.OpenRelaySessionResponse{message: "relay-rolling-3"}, %{host: host}} =
                 CameraMediaForwarder.open_relay_session(request, opts(ctx.old_node))

        assert Atom.to_string(host) =~ "#{ctx.basename}@"
      end)

    assert log == ""
  end

  test "a capable core's real failure is surfaced and logged, not hidden as :peer_too_old", ctx do
    _new_node =
      start_core_peer!(:new_core, ctx.basename, """
      defmodule #{inspect(@ingress)} do
        def open_relay_session(_request), do: raise("ingress exploded")
      end
      """)

    request = %Camera.OpenRelaySessionRequest{relay_session_id: "relay-rolling-4"}
    Application.put_env(:serviceradar_core, :cluster_rpc_undef_wait_ms, 5_000)
    started = System.monotonic_time(:millisecond)

    log =
      capture_log(fn ->
        assert {:error, :core_unavailable} =
                 CameraMediaForwarder.open_relay_session(request, opts(ctx.old_node))
      end)

    assert System.monotonic_time(:millisecond) - started < 2_000
    assert log =~ "Failed to open camera relay session on core-elx ingress"
    assert log =~ "ingress exploded"
  end

  defp opts(core_node) do
    [core_node: core_node, ingress_module: @ingress, rpc_module: :rpc, timeout: 2_000]
  end

  defp ensure_distribution_started! do
    if !Node.alive?() do
      {_, 0} = System.cmd("epmd", ["-daemon"])
      {:ok, _} = :net_kernel.start([:"camera_rolling_#{System.unique_integer([:positive])}", :shortnames])
      on_exit(fn -> :net_kernel.stop() end)
    end
  end

  defp start_core_peer!(id, peer_name, code) do
    peer =
      start_supervised!(%{
        id: id,
        start: {:peer, :start_link, [peer_opts(peer_name)]},
        restart: :temporary
      })

    configure_peer(peer, code)
  end

  defp start_peer(peer_name), do: :peer.start(peer_opts(peer_name))

  defp peer_opts(peer_name) do
    %{
      name: String.to_atom(peer_name),
      connection: :standard_io,
      args: [~c"+S", ~c"2", ~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
    }
  end

  defp configure_peer(peer, code) do
    core_node = :peer.call(peer, :erlang, :node, [])
    :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])
    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:elixir])
    :ok = :peer.call(peer, Code, :put_compiler_option, [:ignore_module_conflict, true])
    :peer.call(peer, Code, :compile_string, [code])
    true = Node.connect(core_node)
    core_node
  end

  defp safe_stop(peer) do
    :peer.stop(peer)
  catch
    _, _ -> :ok
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
