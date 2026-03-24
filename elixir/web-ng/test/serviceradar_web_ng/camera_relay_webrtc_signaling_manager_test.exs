defmodule ServiceRadarWebNG.CameraRelayWebRTCSignalingManagerTest do
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.CameraRelayWebRTCSignalingManager

  defmodule RemoteManagerStub do
    @moduledoc false
    use GenServer

    def start_link(test_pid) do
      GenServer.start_link(__MODULE__, test_pid, name: __MODULE__)
    end

    def init(test_pid), do: {:ok, test_pid}

    def create_session(relay_session_id, opts) do
      send(Process.whereis(__MODULE__), {:create_session, relay_session_id, opts})
      {:ok, %{viewer_session_id: Ecto.UUID.generate(), signaling_state: "viewer_authorized"}}
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

    def handle_info(message, test_pid) do
      send(test_pid, message)
      {:noreply, test_pid}
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

  test "returns unavailable when no core-elx signaling manager is reachable" do
    Application.put_env(:serviceradar_web_ng, :camera_relay_webrtc_rpc_nodes, [])

    assert {:error, message} =
             CameraRelayWebRTCSignalingManager.create_session(Ecto.UUID.generate(), scope: :test)

    assert message == "camera relay webrtc signaling unavailable"
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
