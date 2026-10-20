defmodule ServiceRadar.Observability.StatefulAlertEngine.PeerReadinessTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.StatefulAlertEngine.PeerReadiness

  @moduletag :cluster

  setup do
    ensure_distribution!()
    :ok
  end

  test "an evaluator peer that cannot take durable work refuses admission, and the refusal is not reused" do
    peer = start_peer!()

    # EventWriter is on but the peer has no repo, so its capability is unavailable.
    set_peer_env(peer, :event_writer_enabled, true)
    assert {:error, :alert_evaluation_peer_not_ready} = PeerReadiness.check()

    set_peer_env(peer, :event_writer_enabled, false)
    assert :ok = PeerReadiness.check()
  end

  test "a peer that recovers within the retry pause does not refuse admission" do
    peer = start_peer!()
    set_peer_env(peer, :event_writer_enabled, true)

    # The first query refuses within milliseconds; the retry runs 250 ms later.
    recover =
      Task.async(fn ->
        Process.sleep(150)
        set_peer_env(peer, :event_writer_enabled, false)
      end)

    assert :ok = PeerReadiness.check()
    Task.await(recover)
  end

  test "a peer on a release without readiness/0 is checked with the per-role calls" do
    peer = start_peer!()

    # An older release has no readiness/0, so the call fails with :undef.
    {:ok, _apps} = :erpc.call(peer, :application, :ensure_all_started, [:elixir])

    :erpc.call(peer, Code, :compile_string, [
      "defmodule ServiceRadar.Observability.StatefulAlertEngine.PeerReadiness do end"
    ])

    assert :ok = PeerReadiness.check()

    set_peer_env(peer, :event_writer_enabled, true)
    assert {:error, :alert_evaluation_peer_not_ready} = PeerReadiness.check()
  end

  test "a passing result is reused only while cluster membership is unchanged" do
    start_supervised!(PeerReadiness)
    peer = start_peer!()
    assert :ok = PeerReadiness.check()

    set_peer_env(peer, :event_writer_enabled, true)
    assert :ok = PeerReadiness.check()

    # A node joining invalidates the cached result, so the refusal surfaces.
    start_peer!()
    assert {:error, :alert_evaluation_peer_not_ready} = PeerReadiness.check()
  end

  defp ensure_distribution! do
    if !Node.alive?() do
      case System.cmd("epmd", ["-daemon"]) do
        {_output, 0} -> :ok
        {output, code} -> flunk("failed to start epmd (#{code}): #{output}")
      end

      assert {:ok, _pid} = :net_kernel.start([:alert_peer_readiness, :shortnames])
    end

    Node.set_cookie(:alert_peer_readiness_test)
  end

  defp start_peer! do
    name = String.to_atom("alert_peer_#{System.unique_integer([:positive])}")

    {:ok, peer, node} =
      :peer.start_link(%{
        name: name,
        args: [~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
      })

    on_exit(fn -> stop_peer(peer) end)
    assert :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])
    assert node in Node.list()
    node
  end

  defp set_peer_env(node, key, value),
    do: :ok = :erpc.call(node, Application, :put_env, [:serviceradar_core, key, value])

  defp stop_peer(peer) do
    if Process.alive?(peer), do: :peer.stop(peer)
  catch
    :exit, _reason -> :ok
  end
end
