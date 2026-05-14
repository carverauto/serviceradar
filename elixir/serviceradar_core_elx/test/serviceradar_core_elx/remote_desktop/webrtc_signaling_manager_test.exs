defmodule ServiceRadarCoreElx.RemoteDesktop.WebRTCSignalingManagerTest do
  use ExUnit.Case, async: false

  alias Membrane.WebRTC.Signaling
  alias ServiceRadarCoreElx.RemoteDesktop.WebRTCSignalingManager

  defmodule SessionTrackerStub do
    @moduledoc false

    def fetch_session(session_id) do
      send(test_pid(), {:fetch_session, session_id})

      case Application.get_env(:serviceradar_core_elx, :remote_desktop_webrtc_fetch_result, :ok) do
        :ok ->
          {:ok, %{id: session_id, protocol: :rdp, status: :active}}

        other ->
          other
      end
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core_elx, :remote_desktop_webrtc_test_pid)
    end
  end

  defmodule BareSessionTrackerStub do
    @moduledoc false

    def fetch_session(session_id) do
      send(test_pid(), {:fetch_session, session_id})
      %{id: session_id, protocol: :rdp, status: :active}
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core_elx, :remote_desktop_webrtc_test_pid)
    end
  end

  defmodule MissingSessionTrackerStub do
    @moduledoc false

    def fetch_session(session_id) do
      send(test_pid(), {:fetch_session, session_id})
      nil
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core_elx, :remote_desktop_webrtc_test_pid)
    end
  end

  defmodule MediaManagerStub do
    @moduledoc false

    def add_webrtc_viewer(session_id, viewer_session_id, signaling, opts) do
      send(test_pid(), {:add_webrtc_viewer, session_id, viewer_session_id, opts})
      :ok = Signaling.register_peer(signaling, message_format: :json_data, pid: self())

      :ok =
        Signaling.signal(
          signaling,
          %{"type" => "sdp_offer", "data" => %{"type" => "offer", "sdp" => "v=0\r\ndesktop-offer"}}
        )

      :ok
    end

    def remove_webrtc_viewer(session_id, viewer_session_id) do
      send(test_pid(), {:remove_webrtc_viewer, session_id, viewer_session_id})
      :ok
    end

    def apply_browser_ack(session_id, viewer_session_id, ack, opts) do
      send(test_pid(), {:apply_browser_ack, session_id, viewer_session_id, ack, opts})

      Application.get_env(:serviceradar_core_elx, :remote_desktop_webrtc_media_ack_result, {:ok, %{}})
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core_elx, :remote_desktop_webrtc_test_pid)
    end
  end

  setup do
    previous_fetch_result = Application.get_env(:serviceradar_core_elx, :remote_desktop_webrtc_fetch_result)
    previous_media_ack_result = Application.get_env(:serviceradar_core_elx, :remote_desktop_webrtc_media_ack_result)
    previous_test_pid = Application.get_env(:serviceradar_core_elx, :remote_desktop_webrtc_test_pid)

    Application.put_env(:serviceradar_core_elx, :remote_desktop_webrtc_test_pid, self())

    on_exit(fn ->
      restore_env(:remote_desktop_webrtc_fetch_result, previous_fetch_result)
      restore_env(:remote_desktop_webrtc_media_ack_result, previous_media_ack_result)
      restore_env(:remote_desktop_webrtc_test_pid, previous_test_pid)
    end)

    :ok
  end

  test "creates and closes desktop viewer signaling sessions owned by core-elx" do
    session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name, session_tracker: SessionTrackerStub, media_manager: MediaManagerStub, session_ttl_ms: 5_000}
    )

    assert {:ok,
            %{viewer_session_id: viewer_session_id, signaling_state: "offer_created", offer_sdp: "v=0\r\ndesktop-offer"}} =
             WebRTCSignalingManager.create_session(session_id, server: server_name)

    assert_receive {:fetch_session, ^session_id}
    assert_receive {:add_webrtc_viewer, ^session_id, ^viewer_session_id, opts}
    assert opts[:transport] == "webrtc_desktop_media"

    assert {:ok, %{viewer_session_id: ^viewer_session_id, signaling_state: "closed"}} =
             WebRTCSignalingManager.close_session(session_id, viewer_session_id, server: server_name)

    assert_receive {:remove_webrtc_viewer, ^session_id, ^viewer_session_id}
  end

  test "submits answers and buffers browser ICE candidates" do
    session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name, session_tracker: SessionTrackerStub, media_manager: MediaManagerStub, session_ttl_ms: 5_000}
    )

    assert {:ok, %{viewer_session_id: viewer_session_id}} =
             WebRTCSignalingManager.create_session(session_id, server: server_name)

    assert {:ok, %{signaling_state: "answer_applied"}} =
             WebRTCSignalingManager.submit_answer(session_id, viewer_session_id, "v=0\r\nanswer", server: server_name)

    candidate = %{"candidate" => "candidate:1 1 UDP 1234 10.0.0.1 4000 typ host"}

    assert {:ok, %{signaling_state: "candidate_buffered"}} =
             WebRTCSignalingManager.add_ice_candidate(session_id, viewer_session_id, candidate, server: server_name)
  end

  test "routes browser media acknowledgements through the configured media manager" do
    session_id = Ecto.UUID.generate()
    server_name = unique_server_name()
    media_ack_result = {:ok, %{pending_credit_bytes: 4_096, last_accepted_sequence: 7}}

    Application.put_env(:serviceradar_core_elx, :remote_desktop_webrtc_media_ack_result, media_ack_result)

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name, session_tracker: SessionTrackerStub, media_manager: MediaManagerStub, session_ttl_ms: 5_000}
    )

    assert {:ok, %{viewer_session_id: viewer_session_id}} =
             WebRTCSignalingManager.create_session(session_id, server: server_name)

    ack = %{"media_session_id" => "media-1", "last_accepted_seq" => 7, "credit_bytes" => 4_096}

    assert {:ok,
            %{
              viewer_session_id: ^viewer_session_id,
              media_ack_state: %{pending_credit_bytes: 4_096, last_accepted_sequence: 7}
            }} =
             WebRTCSignalingManager.apply_media_ack(session_id, viewer_session_id, ack, server: server_name)

    assert_receive {:apply_browser_ack, ^session_id, ^viewer_session_id, ^ack, opts}
    refute Keyword.has_key?(opts, :server)
  end

  test "propagates browser media acknowledgement rejections" do
    session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    Application.put_env(:serviceradar_core_elx, :remote_desktop_webrtc_media_ack_result, {:error, :replayed_ack})

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name, session_tracker: SessionTrackerStub, media_manager: MediaManagerStub, session_ttl_ms: 5_000}
    )

    assert {:ok, %{viewer_session_id: viewer_session_id}} =
             WebRTCSignalingManager.create_session(session_id, server: server_name)

    assert {:error, :replayed_ack} =
             WebRTCSignalingManager.apply_media_ack(
               session_id,
               viewer_session_id,
               %{"media_session_id" => "media-1", "last_accepted_seq" => 3},
               server: server_name
             )
  end

  test "rejects browser media acknowledgements for unknown viewers" do
    session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name, session_tracker: SessionTrackerStub, media_manager: MediaManagerStub, session_ttl_ms: 5_000}
    )

    assert {:ok, %{viewer_session_id: viewer_session_id}} =
             WebRTCSignalingManager.create_session(session_id, server: server_name)

    assert {:error, :viewer_session_not_found} =
             WebRTCSignalingManager.apply_media_ack(
               session_id,
               "missing-#{viewer_session_id}",
               %{"media_session_id" => "media-1", "last_accepted_seq" => 1},
               server: server_name
             )
  end

  test "expires idle viewer signaling sessions" do
    session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name, session_tracker: SessionTrackerStub, media_manager: MediaManagerStub, session_ttl_ms: 10}
    )

    assert {:ok, %{viewer_session_id: viewer_session_id}} =
             WebRTCSignalingManager.create_session(session_id, server: server_name)

    assert_receive {:remove_webrtc_viewer, ^session_id, ^viewer_session_id}, 250
  end

  test "rejects missing desktop sessions" do
    Application.put_env(:serviceradar_core_elx, :remote_desktop_webrtc_fetch_result, {:error, :not_found})
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name, session_tracker: SessionTrackerStub, media_manager: MediaManagerStub, session_ttl_ms: 5_000}
    )

    assert {:error, :not_found} =
             WebRTCSignalingManager.create_session(Ecto.UUID.generate(), server: server_name)
  end

  test "rejects nil sessions from the real tracker contract" do
    session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name,
       session_tracker: MissingSessionTrackerStub,
       media_manager: MediaManagerStub,
       session_ttl_ms: 5_000}
    )

    assert {:error, :not_found} =
             WebRTCSignalingManager.create_session(session_id, server: server_name)

    assert_receive {:fetch_session, ^session_id}
  end

  test "accepts bare session maps from injected trackers" do
    session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name, session_tracker: BareSessionTrackerStub, media_manager: MediaManagerStub, session_ttl_ms: 5_000}
    )

    assert {:ok,
            %{viewer_session_id: viewer_session_id, signaling_state: "offer_created", offer_sdp: "v=0\r\ndesktop-offer"}} =
             WebRTCSignalingManager.create_session(session_id, server: server_name)

    assert_receive {:fetch_session, ^session_id}
    assert_receive {:add_webrtc_viewer, ^session_id, ^viewer_session_id, _opts}
  end

  test "rejects unsupported protocols from the session tracker" do
    Application.put_env(
      :serviceradar_core_elx,
      :remote_desktop_webrtc_fetch_result,
      {:error, :unsupported_remote_desktop_session}
    )

    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name, session_tracker: SessionTrackerStub, media_manager: MediaManagerStub, session_ttl_ms: 5_000}
    )

    assert {:error, :unsupported_remote_desktop_session} =
             WebRTCSignalingManager.create_session(Ecto.UUID.generate(), server: server_name)
  end

  test "returns unavailable until a desktop media manager is configured" do
    session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager, name: server_name, session_tracker: SessionTrackerStub, session_ttl_ms: 5_000}
    )

    assert {:error, "desktop media plane is not available"} =
             WebRTCSignalingManager.create_session(session_id, server: server_name)
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core_elx, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core_elx, key, value)
  defp unique_server_name, do: :"remote_desktop_webrtc_core_test_#{System.unique_integer([:positive])}"
end
