defmodule ServiceRadarCoreElx.CameraRelay.WebRTCSignalingManagerTest do
  use ExUnit.Case, async: false

  alias Membrane.WebRTC.Signaling
  alias ServiceRadar.Camera.RelayPubSub
  alias ServiceRadarCoreElx.CameraRelay.WebRTCSignalingManager

  defmodule SessionTrackerStub do
    @moduledoc false
    def fetch_session(relay_session_id) do
      send(test_pid(), {:fetch_session, relay_session_id})

      case Application.get_env(:serviceradar_core_elx, :camera_relay_webrtc_fetch_result, :ok) do
        :ok -> {:ok, %{relay_session_id: relay_session_id, media_ingest_id: "core-media-1"}}
        other -> other
      end
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core_elx, :camera_relay_webrtc_test_pid)
    end
  end

  defmodule PipelineManagerStub do
    @moduledoc false

    def add_webrtc_viewer(relay_session_id, viewer_session_id, signaling, _opts) do
      send(test_pid(), {:add_webrtc_viewer, relay_session_id, viewer_session_id})
      :ok = Signaling.register_peer(signaling, message_format: :json_data, pid: self())

      :ok =
        Signaling.signal(
          signaling,
          %{"type" => "sdp_offer", "data" => %{"type" => "offer", "sdp" => "v=0\r\nstub-offer"}}
        )

      :ok
    end

    def remove_webrtc_viewer(relay_session_id, viewer_session_id) do
      send(test_pid(), {:remove_webrtc_viewer, relay_session_id, viewer_session_id})
      :ok
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core_elx, :camera_relay_webrtc_test_pid)
    end
  end

  setup do
    previous_fetch_result = Application.get_env(:serviceradar_core_elx, :camera_relay_webrtc_fetch_result)
    previous_test_pid = Application.get_env(:serviceradar_core_elx, :camera_relay_webrtc_test_pid)

    Application.put_env(:serviceradar_core_elx, :camera_relay_webrtc_test_pid, self())
    :ok = RelayPubSub.subscribe_viewer_control()

    on_exit(fn ->
      restore_env(:camera_relay_webrtc_fetch_result, previous_fetch_result)
      restore_env(:camera_relay_webrtc_test_pid, previous_test_pid)
    end)

    :ok
  end

  test "creates and closes relay-scoped viewer sessions owned by core-elx" do
    relay_session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name,
       session_tracker: SessionTrackerStub,
       pipeline_manager: PipelineManagerStub,
       session_ttl_ms: 5_000}
    )

    assert {:ok,
            %{viewer_session_id: viewer_session_id, signaling_state: "offer_created", offer_sdp: "v=0\r\nstub-offer"}} =
             WebRTCSignalingManager.create_session(relay_session_id, server: server_name)

    assert_receive {:fetch_session, ^relay_session_id}
    assert_receive {:add_webrtc_viewer, ^relay_session_id, ^viewer_session_id}

    assert_receive {:camera_relay_viewer_join,
                    %{relay_session_id: ^relay_session_id, viewer_id: ^viewer_session_id, transport: "membrane_webrtc"}}

    assert {:ok, %{viewer_session_id: ^viewer_session_id, signaling_state: "closed"}} =
             WebRTCSignalingManager.close_session(relay_session_id, viewer_session_id, server: server_name)

    assert_receive {:camera_relay_viewer_leave,
                    %{relay_session_id: ^relay_session_id, viewer_id: ^viewer_session_id, reason: reason}}

    assert_receive {:remove_webrtc_viewer, ^relay_session_id, ^viewer_session_id}
    assert reason == "viewer closed webrtc signaling session"
  end

  test "expires idle viewer signaling sessions" do
    relay_session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name, session_tracker: SessionTrackerStub, pipeline_manager: PipelineManagerStub, session_ttl_ms: 10}
    )

    assert {:ok, %{viewer_session_id: viewer_session_id}} =
             WebRTCSignalingManager.create_session(relay_session_id, server: server_name)

    assert_receive {:camera_relay_viewer_join, %{relay_session_id: ^relay_session_id, viewer_id: ^viewer_session_id}},
                   100

    assert_receive {:camera_relay_viewer_leave,
                    %{relay_session_id: ^relay_session_id, viewer_id: ^viewer_session_id, reason: reason}},
                   250

    assert_receive {:remove_webrtc_viewer, ^relay_session_id, ^viewer_session_id}
    assert reason == "webrtc signaling session expired"
  end

  test "rejects signaling sessions for missing relay sessions" do
    Application.put_env(:serviceradar_core_elx, :camera_relay_webrtc_fetch_result, {:error, :not_found})
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name,
       session_tracker: SessionTrackerStub,
       pipeline_manager: PipelineManagerStub,
       session_ttl_ms: 5_000}
    )

    assert {:error, :not_found} =
             WebRTCSignalingManager.create_session(Ecto.UUID.generate(), server: server_name)
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core_elx, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core_elx, key, value)
  defp unique_server_name, do: :"camera_relay_webrtc_core_test_#{System.unique_integer([:positive])}"
end
