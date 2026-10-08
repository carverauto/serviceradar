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

  defmodule BareSessionTrackerStub do
    @moduledoc false

    def fetch_session(relay_session_id) do
      send(test_pid(), {:fetch_session, relay_session_id})
      %{relay_session_id: relay_session_id, media_ingest_id: "core-media-1"}
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core_elx, :camera_relay_webrtc_test_pid)
    end
  end

  defmodule MissingSessionTrackerStub do
    @moduledoc false

    def fetch_session(relay_session_id) do
      send(test_pid(), {:fetch_session, relay_session_id})
      nil
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

  # Stands in for the WebRTC sink on the far side of the signaling channel:
  # sends the offer and reports every message the manager signals to it.
  defmodule SinkPeerPipelineManagerStub do
    @moduledoc false

    def add_webrtc_viewer(relay_session_id, viewer_session_id, signaling, _opts) do
      test_pid = Application.fetch_env!(:serviceradar_core_elx, :camera_relay_webrtc_test_pid)
      send(test_pid, {:add_webrtc_viewer, relay_session_id, viewer_session_id})

      spawn(fn ->
        :ok = Signaling.register_peer(signaling, message_format: :json_data, pid: self())

        :ok =
          Signaling.signal(
            signaling,
            %{"type" => "sdp_offer", "data" => %{"type" => "offer", "sdp" => "v=0\r\nstub-offer"}}
          )

        forward_signals(test_pid)
      end)

      :ok
    end

    def remove_webrtc_viewer(relay_session_id, viewer_session_id) do
      test_pid = Application.fetch_env!(:serviceradar_core_elx, :camera_relay_webrtc_test_pid)
      send(test_pid, {:remove_webrtc_viewer, relay_session_id, viewer_session_id})
      :ok
    end

    defp forward_signals(test_pid) do
      receive do
        {:membrane_webrtc_signaling, _pid, message, _metadata} ->
          send(test_pid, {:sink_received, message})
          forward_signals(test_pid)
      end
    end
  end

  # Registers like the real WebRTC sink (an element peer), so when this process
  # dies the Signaling process stops with its crash reason, exactly as it does
  # when a viewer's sink crashes in the relay pipeline.
  defmodule ElementPeerPipelineManagerStub do
    @moduledoc false

    def add_webrtc_viewer(relay_session_id, viewer_session_id, signaling, _opts) do
      test_pid = Application.fetch_env!(:serviceradar_core_elx, :camera_relay_webrtc_test_pid)

      element =
        spawn(fn ->
          :ok = Signaling.register_element(signaling)

          :ok =
            Signaling.signal(signaling, %ExWebRTC.SessionDescription{type: :offer, sdp: "v=0\r\nstub-offer"})

          receive do
            :never -> :ok
          end
        end)

      send(test_pid, {:element_peer, viewer_session_id, element})
      send(test_pid, {:add_webrtc_viewer, relay_session_id, viewer_session_id})
      :ok
    end

    def remove_webrtc_viewer(relay_session_id, viewer_session_id) do
      test_pid = Application.fetch_env!(:serviceradar_core_elx, :camera_relay_webrtc_test_pid)
      send(test_pid, {:remove_webrtc_viewer, relay_session_id, viewer_session_id})
      :ok
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

    manager_opts = [
      name: server_name,
      session_tracker: SessionTrackerStub,
      pipeline_manager: PipelineManagerStub,
      session_ttl_ms: 10
    ]

    start_supervised!({WebRTCSignalingManager, manager_opts})

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

  test "rejects nil relay sessions from the real tracker contract" do
    relay_session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name,
       session_tracker: MissingSessionTrackerStub,
       pipeline_manager: PipelineManagerStub,
       session_ttl_ms: 5_000}
    )

    assert {:error, :not_found} =
             WebRTCSignalingManager.create_session(relay_session_id, server: server_name)

    assert_receive {:fetch_session, ^relay_session_id}
  end

  test "accepts relay sessions from the real tracker contract" do
    relay_session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name,
       session_tracker: BareSessionTrackerStub,
       pipeline_manager: PipelineManagerStub,
       session_ttl_ms: 5_000}
    )

    assert {:ok,
            %{viewer_session_id: viewer_session_id, signaling_state: "offer_created", offer_sdp: "v=0\r\nstub-offer"}} =
             WebRTCSignalingManager.create_session(relay_session_id, server: server_name)

    assert_receive {:fetch_session, ^relay_session_id}
    assert_receive {:add_webrtc_viewer, ^relay_session_id, ^viewer_session_id}
  end

  test "holds browser ICE candidates until the SDP answer and forwards them after it, in order" do
    relay_session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name,
       session_tracker: SessionTrackerStub,
       pipeline_manager: SinkPeerPipelineManagerStub,
       session_ttl_ms: 5_000}
    )

    assert {:ok, %{viewer_session_id: viewer_session_id}} =
             WebRTCSignalingManager.create_session(relay_session_id, server: server_name)

    first = %{"candidate" => "candidate:1 1 UDP 2122252543 192.0.2.10 49152 typ host", "sdpMid" => "0"}
    second = %{"candidate" => "candidate:2 1 UDP 2122252542 192.0.2.11 49153 typ host", "sdpMid" => "0"}

    assert {:ok, _session} =
             WebRTCSignalingManager.add_ice_candidate(relay_session_id, viewer_session_id, first, server: server_name)

    assert {:ok, _session} =
             WebRTCSignalingManager.add_ice_candidate(relay_session_id, viewer_session_id, second, server: server_name)

    # The sink cannot apply a candidate without a remote description.
    refute_receive {:sink_received, %{"type" => "ice_candidate"}}, 100

    assert {:ok, %{signaling_state: "answer_applied"}} =
             WebRTCSignalingManager.submit_answer(relay_session_id, viewer_session_id, "v=0\r\nanswer",
               server: server_name
             )

    assert_receive {:sink_received, %{"type" => "sdp_answer"}}
    assert_receive {:sink_received, %{"type" => "ice_candidate", "data" => ^first}}
    assert_receive {:sink_received, %{"type" => "ice_candidate", "data" => ^second}}

    third = %{"candidate" => "candidate:3 1 UDP 2122252541 192.0.2.12 49154 typ host", "sdpMid" => "0"}

    assert {:ok, _session} =
             WebRTCSignalingManager.add_ice_candidate(relay_session_id, viewer_session_id, third, server: server_name)

    assert_receive {:sink_received, %{"type" => "ice_candidate", "data" => ^third}}
  end

  test "releases a viewer whose sink crashed inside the relay pipeline" do
    relay_session_id = Ecto.UUID.generate()
    :ok = RelayPubSub.subscribe(relay_session_id)
    server_name = unique_server_name()

    manager =
      start_supervised!(
        {WebRTCSignalingManager,
         name: server_name,
         session_tracker: SessionTrackerStub,
         pipeline_manager: PipelineManagerStub,
         session_ttl_ms: 5_000}
      )

    assert {:ok, %{viewer_session_id: viewer_session_id}} =
             WebRTCSignalingManager.create_session(relay_session_id, server: server_name)

    send(
      manager,
      {:camera_relay_member_crashed, :webrtc_viewer, relay_session_id, viewer_session_id,
       {:membrane_child_crash, :webrtc, {:shutdown, :connection_failed}}}
    )

    assert_receive {:camera_relay_viewer_leave,
                    %{relay_session_id: ^relay_session_id, viewer_id: ^viewer_session_id, reason: reason}}

    assert reason == "webrtc viewer connection failed"

    assert_receive {:camera_relay_webrtc_closed,
                    %{
                      relay_session_id: ^relay_session_id,
                      viewer_id: ^viewer_session_id,
                      reason: "webrtc viewer connection failed"
                    }}

    assert {:error, :viewer_session_not_found} =
             WebRTCSignalingManager.close_session(relay_session_id, viewer_session_id, server: server_name)
  end

  test "survives a viewer whose signaling peer crashed and releases only that viewer" do
    relay_session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    manager =
      start_supervised!(
        {WebRTCSignalingManager,
         name: server_name,
         session_tracker: SessionTrackerStub,
         pipeline_manager: ElementPeerPipelineManagerStub,
         session_ttl_ms: 5_000}
      )

    assert {:ok, %{viewer_session_id: crashed_viewer}} =
             WebRTCSignalingManager.create_session(relay_session_id, server: server_name)

    assert {:ok, %{viewer_session_id: other_viewer}} =
             WebRTCSignalingManager.create_session(relay_session_id, server: server_name)

    assert_receive {:element_peer, ^crashed_viewer, element}
    Process.exit(element, :sink_crashed)

    assert_receive {:camera_relay_viewer_leave,
                    %{relay_session_id: ^relay_session_id, viewer_id: ^crashed_viewer, reason: reason}}

    assert reason == "webrtc viewer connection failed"
    # Same process: one viewer's crash must not restart the manager and drop
    # every other viewer's session.
    assert GenServer.whereis(server_name) == manager

    assert {:error, :viewer_session_not_found} =
             WebRTCSignalingManager.close_session(relay_session_id, crashed_viewer, server: server_name)

    assert {:ok, %{viewer_session_id: ^other_viewer, signaling_state: "closed"}} =
             WebRTCSignalingManager.close_session(relay_session_id, other_viewer, server: server_name)
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core_elx, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core_elx, key, value)
  defp unique_server_name, do: :"camera_relay_webrtc_core_test_#{System.unique_integer([:positive])}"
end
