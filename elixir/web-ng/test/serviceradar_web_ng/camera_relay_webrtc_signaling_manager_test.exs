defmodule ServiceRadarWebNG.CameraRelayWebRTCSignalingManagerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Camera.RelayHosts
  alias ServiceRadarWebNG.CameraRelayWebRTCSignalingManager

  @moduletag :db_free

  defmodule RemoteManagerStub do
    @moduledoc false
    use GenServer

    def start_link(test_pid) do
      GenServer.start_link(__MODULE__, test_pid, name: __MODULE__)
    end

    def init(test_pid), do: {:ok, %{test_pid: test_pid, create_results: []}}

    # Each queued result answers one node's create_session call, in node order.
    def queue_create_results(results), do: GenServer.call(__MODULE__, {:queue_create_results, results})

    def create_session(relay_session_id, opts) do
      send(Process.whereis(__MODULE__), {:create_session, relay_session_id, opts})

      case GenServer.call(__MODULE__, :next_create_result) do
        nil -> {:ok, %{viewer_session_id: Ecto.UUID.generate(), signaling_state: "viewer_authorized"}}
        result -> result
      end
    end

    def submit_answer(relay_session_id, viewer_session_id, answer_sdp, opts) do
      send(Process.whereis(__MODULE__), {:submit_answer, relay_session_id, viewer_session_id, answer_sdp, opts})
      {:ok, %{viewer_session_id: viewer_session_id, signaling_state: "answer_applied"}}
    end

    def add_ice_candidate(relay_session_id, viewer_session_id, candidate, opts) do
      send(Process.whereis(__MODULE__), {:add_candidate, relay_session_id, viewer_session_id, candidate, opts})
      {:ok, %{viewer_session_id: viewer_session_id, signaling_state: "candidate_buffered"}}
    end

    def close_session(relay_session_id, viewer_session_id, opts) do
      send(Process.whereis(__MODULE__), {:close_session, relay_session_id, viewer_session_id, opts})
      {:ok, %{viewer_session_id: viewer_session_id, signaling_state: "closed"}}
    end

    def handle_call({:queue_create_results, results}, _from, state) do
      {:reply, :ok, %{state | create_results: results}}
    end

    def handle_call(:next_create_result, _from, %{create_results: [next | rest]} = state) do
      {:reply, next, %{state | create_results: rest}}
    end

    def handle_call(:next_create_result, _from, state), do: {:reply, nil, state}

    def handle_info(message, state) do
      send(state.test_pid, message)
      {:noreply, state}
    end
  end

  setup do
    previous_manager = Application.get_env(:serviceradar_web_ng, :camera_relay_webrtc_remote_manager)
    previous_nodes = Application.get_env(:serviceradar_web_ng, :camera_relay_webrtc_rpc_nodes)

    start_supervised!({RemoteManagerStub, self()})

    Application.put_env(:serviceradar_web_ng, :camera_relay_webrtc_remote_manager, RemoteManagerStub)
    Application.put_env(:serviceradar_web_ng, :camera_relay_webrtc_rpc_nodes, [Node.self()])

    on_exit(fn ->
      restore_env(:camera_relay_webrtc_remote_manager, previous_manager)
      restore_env(:camera_relay_webrtc_rpc_nodes, previous_nodes)
    end)

    :ok
  end

  test "delegates create and close to the core-elx signaling manager" do
    relay_session_id = Ecto.UUID.generate()
    viewer_session_id = Ecto.UUID.generate()

    assert {:ok, %{signaling_state: "viewer_authorized"}} =
             CameraRelayWebRTCSignalingManager.create_session(relay_session_id, scope: :test)

    assert_receive {:create_session, ^relay_session_id, opts}
    assert opts[:scope] == :test

    assert {:ok, %{viewer_session_id: ^viewer_session_id, signaling_state: "closed"}} =
             CameraRelayWebRTCSignalingManager.close_session(
               relay_session_id,
               viewer_session_id,
               scope: :test
             )

    assert_receive {:close_session, ^relay_session_id, ^viewer_session_id, opts}
    assert opts[:scope] == :test
  end

  # The hosting node advertises the relay, so the call goes straight there; with
  # no nodes configured to scan, only that route can reach the manager.
  test "sends a call straight to the node advertising the relay" do
    if is_nil(Process.whereis(:serviceradar_camera_relay_hosts)), do: start_supervised!(RelayHosts)
    Application.put_env(:serviceradar_web_ng, :camera_relay_webrtc_rpc_nodes, [])

    relay_session_id = Ecto.UUID.generate()
    host = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> send(host, :stop) end)
    :ok = RelayHosts.advertise(relay_session_id, host)

    assert {:ok, %{signaling_state: "viewer_authorized"}} =
             CameraRelayWebRTCSignalingManager.create_session(relay_session_id, scope: :test)

    assert_receive {:create_session, ^relay_session_id, _opts}
  end

  # The advertised host is the only node allowed to run the call. A second
  # queued success would be returned if the timeout were sent around again.
  test "does not ask other nodes when the advertised host does not answer" do
    if is_nil(Process.whereis(:serviceradar_camera_relay_hosts)), do: start_supervised!(RelayHosts)
    Application.put_env(:serviceradar_web_ng, :camera_relay_webrtc_rpc_nodes, [Node.self(), Node.self()])

    relay_session_id = Ecto.UUID.generate()
    host = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> send(host, :stop) end)
    :ok = RelayHosts.advertise(relay_session_id, host)
    RemoteManagerStub.queue_create_results([{:badrpc, :timeout}, nil])

    assert {:error, "camera relay webrtc signaling unavailable: :timeout"} =
             CameraRelayWebRTCSignalingManager.create_session(relay_session_id, scope: :test)

    assert_receive {:create_session, ^relay_session_id, _opts}
    refute_receive {:create_session, ^relay_session_id, _opts}
  end

  # A relay lives on the one core-elx node that ingests it; the others answer
  # :not_found. The local node listed twice stands in for two core-elx nodes.
  # An unreachable node has not said the relay is absent, in either order, and
  # for either "not hosted" answer.
  for {label, results, expected} <- [
        {"skips a node that does not host the relay", [{:error, :not_found}, :hosted], :created},
        {"reports not found when no node hosts the relay", [{:error, :not_found}, {:error, :not_found}], :not_found},
        {"keeps looking after a node it cannot reach", [{:badrpc, :timeout}, :hosted], :created},
        {"reports unreachable when another node does not host the relay", [{:badrpc, :timeout}, {:error, :not_found}],
         :unreachable},
        {"reports unreachable when another node has no viewer session",
         [{:badrpc, :timeout}, {:error, :viewer_session_not_found}], :unreachable},
        {"reports unreachable when a node it cannot reach follows one that does not host the relay",
         [{:error, :not_found}, {:badrpc, :nodedown}], :unreachable_later},
        {"reports unreachable when a node it cannot reach follows one with no viewer session",
         [{:error, :viewer_session_not_found}, {:badrpc, :nodedown}], :unreachable_later}
      ] do
    test "create_session #{label}" do
      Application.put_env(:serviceradar_web_ng, :camera_relay_webrtc_rpc_nodes, [Node.self(), Node.self()])

      unquote(Macro.escape(results))
      |> Enum.map(fn
        :hosted -> nil
        result -> result
      end)
      |> RemoteManagerStub.queue_create_results()

      result = CameraRelayWebRTCSignalingManager.create_session(Ecto.UUID.generate(), scope: :test)

      case unquote(expected) do
        :created -> assert {:ok, %{signaling_state: "viewer_authorized"}} = result
        :not_found -> assert result == {:error, :not_found}
        :unreachable -> assert result == {:error, "camera relay webrtc signaling unavailable: :timeout"}
        :unreachable_later -> assert result == {:error, "camera relay webrtc signaling unavailable: :nodedown"}
      end

      assert_receive {:create_session, _relay_session_id, _opts}
      assert_receive {:create_session, _relay_session_id, _opts}
    end
  end

  test "returns unavailable when no core-elx signaling manager is reachable" do
    Application.put_env(:serviceradar_web_ng, :camera_relay_webrtc_rpc_nodes, [])

    assert {:error, message} =
             CameraRelayWebRTCSignalingManager.create_session(Ecto.UUID.generate(), scope: :test)

    assert message == "camera relay webrtc signaling unavailable"
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
