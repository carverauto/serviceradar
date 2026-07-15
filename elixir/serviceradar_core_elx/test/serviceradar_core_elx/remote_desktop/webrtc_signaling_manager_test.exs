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
          {:ok, %{id: session_id, protocol: :rdp, status: :active, requested_by: "actor-1"}}

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
      %{id: session_id, protocol: :rdp, status: :active, requested_by: "actor-1"}
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

    def apply_browser_control(session_id, viewer_session_id, frame, opts) do
      send(test_pid(), {:apply_browser_control, session_id, viewer_session_id, frame, opts})

      Application.get_env(:serviceradar_core_elx, :remote_desktop_webrtc_control_result, {:ok, %{}})
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core_elx, :remote_desktop_webrtc_test_pid)
    end
  end

  defmodule MediaCleanupStub do
    @moduledoc false

    def close_session(session_id) do
      send(
        Application.fetch_env!(:serviceradar_core_elx, :remote_desktop_webrtc_test_pid),
        {:close_desktop_media_session, session_id}
      )

      :ok
    end
  end

  setup do
    previous_fetch_result = Application.get_env(:serviceradar_core_elx, :remote_desktop_webrtc_fetch_result)
    previous_media_ack_result = Application.get_env(:serviceradar_core_elx, :remote_desktop_webrtc_media_ack_result)
    previous_control_result = Application.get_env(:serviceradar_core_elx, :remote_desktop_webrtc_control_result)
    previous_test_pid = Application.get_env(:serviceradar_core_elx, :remote_desktop_webrtc_test_pid)
    previous_media_cleanup = Application.get_env(:serviceradar_core_elx, :remote_desktop_media_cleanup)

    Application.put_env(:serviceradar_core_elx, :remote_desktop_webrtc_test_pid, self())
    Application.put_env(:serviceradar_core_elx, :remote_desktop_media_cleanup, MediaCleanupStub)

    on_exit(fn ->
      restore_env(:remote_desktop_webrtc_fetch_result, previous_fetch_result)
      restore_env(:remote_desktop_webrtc_media_ack_result, previous_media_ack_result)
      restore_env(:remote_desktop_webrtc_control_result, previous_control_result)
      restore_env(:remote_desktop_webrtc_test_pid, previous_test_pid)
      restore_env(:remote_desktop_media_cleanup, previous_media_cleanup)
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
             WebRTCSignalingManager.create_session(session_id,
               server: server_name,
               actor_id: "actor-1"
             )

    assert_receive {:fetch_session, ^session_id}
    assert_receive {:add_webrtc_viewer, ^session_id, ^viewer_session_id, opts}
    assert opts[:transport] == "webrtc_desktop_media"

    assert {:ok, %{viewer_session_id: ^viewer_session_id, signaling_state: "closed"}} =
             WebRTCSignalingManager.close_session(session_id, viewer_session_id,
               server: server_name,
               actor_id: "actor-1"
             )

    assert_receive {:remove_webrtc_viewer, ^session_id, ^viewer_session_id}
    assert_receive {:close_desktop_media_session, ^session_id}
  end

  test "bounds viewers per desktop session and releases capacity after close" do
    session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name,
       session_tracker: SessionTrackerStub,
       media_manager: MediaManagerStub,
       session_ttl_ms: 5_000,
       max_viewers_per_session: 2,
       max_viewers_per_actor: 8,
       max_viewers_global: 16}
    )

    assert {:ok, %{viewer_session_id: first_viewer}} =
             WebRTCSignalingManager.create_session(session_id,
               server: server_name,
               actor_id: "actor-1"
             )

    assert {:ok, %{viewer_session_id: second_viewer}} =
             WebRTCSignalingManager.create_session(session_id,
               server: server_name,
               actor_id: "actor-1"
             )

    assert {:error, {:viewer_limit_exceeded, :session, 2}} =
             WebRTCSignalingManager.create_session(session_id,
               server: server_name,
               actor_id: "actor-1"
             )

    assert map_size(:sys.get_state(server_name).sessions) == 2

    assert {:ok, %{signaling_state: "closed"}} =
             WebRTCSignalingManager.close_session(session_id, first_viewer,
               server: server_name,
               actor_id: "actor-1"
             )

    refute_receive {:close_desktop_media_session, ^session_id}, 25

    assert {:ok, %{viewer_session_id: third_viewer}} =
             WebRTCSignalingManager.create_session(session_id,
               server: server_name,
               actor_id: "actor-1"
             )

    refute third_viewer in [first_viewer, second_viewer]
  end

  test "bounds viewers per actor across desktop sessions" do
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name,
       session_tracker: SessionTrackerStub,
       media_manager: MediaManagerStub,
       session_ttl_ms: 5_000,
       max_viewers_per_session: 4,
       max_viewers_per_actor: 2,
       max_viewers_global: 16}
    )

    for _index <- 1..2 do
      assert {:ok, %{viewer_session_id: _viewer_session_id}} =
               WebRTCSignalingManager.create_session(Ecto.UUID.generate(),
                 server: server_name,
                 actor_id: "actor-1"
               )
    end

    assert {:error, {:viewer_limit_exceeded, :actor, 2}} =
             WebRTCSignalingManager.create_session(Ecto.UUID.generate(),
               server: server_name,
               actor_id: "actor-1"
             )
  end

  test "bounds the total viewers owned by one signaling manager" do
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name,
       session_tracker: SessionTrackerStub,
       media_manager: MediaManagerStub,
       session_ttl_ms: 5_000,
       max_viewers_per_session: 4,
       max_viewers_per_actor: 8,
       max_viewers_global: 2}
    )

    for _index <- 1..2 do
      assert {:ok, %{viewer_session_id: _viewer_session_id}} =
               WebRTCSignalingManager.create_session(Ecto.UUID.generate(),
                 server: server_name,
                 actor_id: "actor-1"
               )
    end

    assert {:error, {:viewer_limit_exceeded, :global, 2}} =
             WebRTCSignalingManager.create_session(Ecto.UUID.generate(),
               server: server_name,
               actor_id: "actor-1"
             )
  end

  test "closes every viewer for an owned terminal desktop session" do
    session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name,
       session_tracker: SessionTrackerStub,
       media_manager: MediaManagerStub,
       session_ttl_ms: 5_000,
       max_viewers_per_session: 2}
    )

    assert {:ok, %{viewer_session_id: first_viewer}} =
             WebRTCSignalingManager.create_session(session_id,
               server: server_name,
               actor_id: "actor-1"
             )

    assert {:ok, %{viewer_session_id: second_viewer}} =
             WebRTCSignalingManager.create_session(session_id,
               server: server_name,
               actor_id: "actor-1"
             )

    assert {:error, :viewer_session_not_found} =
             WebRTCSignalingManager.close_all_for_session(session_id,
               server: server_name,
               actor_id: "actor-2"
             )

    assert map_size(:sys.get_state(server_name).sessions) == 2

    assert {:ok, %{closed_viewer_count: 2}} =
             WebRTCSignalingManager.close_all_for_session(session_id,
               server: server_name,
               actor_id: "actor-1",
               reason: "remote_session_terminal"
             )

    assert_receive {:remove_webrtc_viewer, ^session_id, ^first_viewer}
    assert_receive {:remove_webrtc_viewer, ^session_id, ^second_viewer}
    assert_receive {:close_desktop_media_session, ^session_id}
    assert :sys.get_state(server_name).sessions == %{}
  end

  test "honors the requested viewer id and binds every operation to its actor" do
    session_id = Ecto.UUID.generate()
    viewer_session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name, session_tracker: SessionTrackerStub, media_manager: MediaManagerStub, session_ttl_ms: 5_000}
    )

    assert {:ok, %{viewer_session_id: ^viewer_session_id}} =
             WebRTCSignalingManager.create_session(session_id,
               server: server_name,
               actor_id: "actor-1",
               viewer_session_id: viewer_session_id
             )

    assert_receive {:add_webrtc_viewer, ^session_id, ^viewer_session_id, media_opts}
    assert media_opts[:signaling_manager_opts] == [server: server_name, actor_id: "actor-1"]

    wrong_actor_opts = [server: server_name, actor_id: "actor-2"]

    assert {:error, :viewer_session_not_found} =
             WebRTCSignalingManager.submit_answer(
               session_id,
               viewer_session_id,
               valid_answer_sdp(),
               wrong_actor_opts
             )

    assert {:error, :viewer_session_not_found} =
             WebRTCSignalingManager.add_ice_candidate(
               session_id,
               viewer_session_id,
               %{"candidate" => "candidate:1 1 UDP 1234 8.8.8.8 4000 typ srflx"},
               wrong_actor_opts
             )

    assert {:error, :viewer_session_not_found} =
             WebRTCSignalingManager.apply_media_ack(
               session_id,
               viewer_session_id,
               %{"media_session_id" => "media-1", "last_accepted_seq" => 1},
               wrong_actor_opts
             )

    assert {:error, :viewer_session_not_found} =
             WebRTCSignalingManager.apply_control_frame(
               session_id,
               viewer_session_id,
               %{"frame_type" => "desktop.input"},
               wrong_actor_opts
             )

    assert {:error, :viewer_session_not_found} =
             WebRTCSignalingManager.close_session(
               session_id,
               viewer_session_id,
               wrong_actor_opts
             )

    refute_receive {:apply_browser_ack, ^session_id, ^viewer_session_id, _ack, _opts}
    refute_receive {:apply_browser_control, ^session_id, ^viewer_session_id, _frame, _opts}
    refute_receive {:remove_webrtc_viewer, ^session_id, ^viewer_session_id}

    assert {:ok, %{signaling_state: "closed"}} =
             WebRTCSignalingManager.close_session(session_id, viewer_session_id,
               server: server_name,
               actor_id: "actor-1"
             )

    assert_receive {:remove_webrtc_viewer, ^session_id, ^viewer_session_id}
  end

  test "rejects a caller-selected viewer id that is not a UUID" do
    session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name, session_tracker: SessionTrackerStub, media_manager: MediaManagerStub, session_ttl_ms: 5_000}
    )

    assert {:error, :invalid_viewer_session_id} =
             WebRTCSignalingManager.create_session(session_id,
               server: server_name,
               actor_id: "actor-1",
               viewer_session_id: "not-a-uuid"
             )

    refute_receive {:add_webrtc_viewer, ^session_id, _viewer_session_id, _opts}
  end

  test "rejects viewer creation without a stable actor id" do
    session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name, session_tracker: SessionTrackerStub, media_manager: MediaManagerStub, session_ttl_ms: 5_000}
    )

    assert {:error, :viewer_session_not_found} =
             WebRTCSignalingManager.create_session(session_id, server: server_name)

    refute_receive {:add_webrtc_viewer, ^session_id, _viewer_session_id, _opts}
  end

  test "rejects viewer creation for an actor that does not own the desktop session" do
    session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name, session_tracker: SessionTrackerStub, media_manager: MediaManagerStub, session_ttl_ms: 5_000}
    )

    assert {:error, :viewer_session_not_found} =
             WebRTCSignalingManager.create_session(session_id,
               server: server_name,
               actor_id: "actor-2"
             )

    refute_receive {:add_webrtc_viewer, ^session_id, _viewer_session_id, _opts}
  end

  test "rejects reuse of a live caller-selected viewer id without replacing it" do
    session_id = Ecto.UUID.generate()
    viewer_session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name, session_tracker: SessionTrackerStub, media_manager: MediaManagerStub, session_ttl_ms: 5_000}
    )

    create_opts = [
      server: server_name,
      actor_id: "actor-1",
      viewer_session_id: viewer_session_id
    ]

    assert {:ok, %{viewer_session_id: ^viewer_session_id}} =
             WebRTCSignalingManager.create_session(session_id, create_opts)

    assert_receive {:add_webrtc_viewer, ^session_id, ^viewer_session_id, _opts}

    assert {:error, :viewer_session_not_found} =
             WebRTCSignalingManager.create_session(session_id, create_opts)

    refute_receive {:add_webrtc_viewer, ^session_id, ^viewer_session_id, _opts}

    assert {:ok, %{signaling_state: "closed"}} =
             WebRTCSignalingManager.close_session(session_id, viewer_session_id,
               server: server_name,
               actor_id: "actor-1"
             )
  end

  test "submits answers and buffers browser ICE candidates" do
    session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name, session_tracker: SessionTrackerStub, media_manager: MediaManagerStub, session_ttl_ms: 5_000}
    )

    assert {:ok, %{viewer_session_id: viewer_session_id}} =
             WebRTCSignalingManager.create_session(session_id,
               server: server_name,
               actor_id: "actor-1"
             )

    assert {:ok, %{signaling_state: "answer_applied"}} =
             WebRTCSignalingManager.submit_answer(
               session_id,
               viewer_session_id,
               valid_answer_sdp(),
               server: server_name,
               actor_id: "actor-1"
             )

    candidate = %{"candidate" => "candidate:1 1 UDP 1234 8.8.8.8 4000 typ srflx"}

    assert {:ok, %{signaling_state: "candidate_buffered"}} =
             WebRTCSignalingManager.add_ice_candidate(session_id, viewer_session_id, candidate,
               server: server_name,
               actor_id: "actor-1"
             )
  end

  test "ignores duplicate SDP offers after the initial offer is created" do
    session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name, session_tracker: SessionTrackerStub, media_manager: MediaManagerStub, session_ttl_ms: 5_000}
    )

    assert {:ok,
            %{viewer_session_id: viewer_session_id, signaling_state: "offer_created", offer_sdp: "v=0\r\ndesktop-offer"}} =
             WebRTCSignalingManager.create_session(session_id,
               server: server_name,
               actor_id: "actor-1"
             )

    %{sessions: %{^viewer_session_id => session}} = :sys.get_state(server_name)

    :ok =
      Signaling.signal(
        session.signaling,
        %{"type" => "sdp_offer", "data" => %{"type" => "offer", "sdp" => "v=0\r\nsecond-offer"}}
      )

    %{sessions: %{^viewer_session_id => updated}} = :sys.get_state(server_name)

    assert updated.offer_sdp == "v=0\r\ndesktop-offer"
    assert updated.signaling_state == "offer_created"
  end

  test "rejects untrusted answers and browser ICE candidates before forwarding to ExWebRTC" do
    session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name, session_tracker: SessionTrackerStub, media_manager: MediaManagerStub, session_ttl_ms: 5_000}
    )

    assert {:ok, %{viewer_session_id: viewer_session_id}} =
             WebRTCSignalingManager.create_session(session_id,
               server: server_name,
               actor_id: "actor-1"
             )

    assert {:error, :missing_dtls_fingerprint} =
             WebRTCSignalingManager.submit_answer(session_id, viewer_session_id, "v=0\r\nm=application 9",
               server: server_name,
               actor_id: "actor-1"
             )

    candidate = %{"candidate" => "candidate:1 1 UDP 1234 192.168.1.10 4000 typ host"}

    assert {:error, :blocked_ice_candidate} =
             WebRTCSignalingManager.add_ice_candidate(session_id, viewer_session_id, candidate,
               server: server_name,
               actor_id: "actor-1"
             )
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
             WebRTCSignalingManager.create_session(session_id,
               server: server_name,
               actor_id: "actor-1"
             )

    ack = %{"media_session_id" => "media-1", "last_accepted_seq" => 7, "credit_bytes" => 4_096}

    assert {:ok,
            %{
              viewer_session_id: ^viewer_session_id,
              media_ack_state: %{pending_credit_bytes: 4_096, last_accepted_sequence: 7}
            }} =
             WebRTCSignalingManager.apply_media_ack(session_id, viewer_session_id, ack,
               server: server_name,
               actor_id: "actor-1"
             )

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
             WebRTCSignalingManager.create_session(session_id,
               server: server_name,
               actor_id: "actor-1"
             )

    assert {:error, :replayed_ack} =
             WebRTCSignalingManager.apply_media_ack(
               session_id,
               viewer_session_id,
               %{"media_session_id" => "media-1", "last_accepted_seq" => 3},
               server: server_name,
               actor_id: "actor-1"
             )
  end

  test "routes browser desktop control frames through the configured media manager" do
    session_id = Ecto.UUID.generate()
    server_name = unique_server_name()
    control_result = {:ok, %{control_frame_count: 1, last_control_frame: %{"frame_type" => "desktop.input"}}}

    Application.put_env(:serviceradar_core_elx, :remote_desktop_webrtc_control_result, control_result)

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name, session_tracker: SessionTrackerStub, media_manager: MediaManagerStub, session_ttl_ms: 5_000}
    )

    assert {:ok, %{viewer_session_id: viewer_session_id}} =
             WebRTCSignalingManager.create_session(session_id,
               server: server_name,
               actor_id: "actor-1"
             )

    frame = %{
      "session_id" => session_id,
      "protocol" => "rdp",
      "frame_type" => "desktop.input",
      "input" => %{"kind" => "focus", "focused" => true}
    }

    assert {:ok,
            %{
              viewer_session_id: ^viewer_session_id,
              control_state: %{control_frame_count: 1, last_control_frame: %{"frame_type" => "desktop.input"}}
            }} =
             WebRTCSignalingManager.apply_control_frame(session_id, viewer_session_id, frame,
               server: server_name,
               actor_id: "actor-1"
             )

    assert_receive {:apply_browser_control, ^session_id, ^viewer_session_id, ^frame, opts}
    refute Keyword.has_key?(opts, :server)
  end

  test "rejects browser media acknowledgements for unknown viewers" do
    session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name, session_tracker: SessionTrackerStub, media_manager: MediaManagerStub, session_ttl_ms: 5_000}
    )

    assert {:ok, %{viewer_session_id: viewer_session_id}} =
             WebRTCSignalingManager.create_session(session_id,
               server: server_name,
               actor_id: "actor-1"
             )

    assert {:error, :viewer_session_not_found} =
             WebRTCSignalingManager.apply_media_ack(
               session_id,
               "missing-#{viewer_session_id}",
               %{"media_session_id" => "media-1", "last_accepted_seq" => 1},
               server: server_name,
               actor_id: "actor-1"
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
             WebRTCSignalingManager.create_session(session_id,
               server: server_name,
               actor_id: "actor-1"
             )

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
             WebRTCSignalingManager.create_session(Ecto.UUID.generate(),
               server: server_name,
               actor_id: "actor-1"
             )
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
             WebRTCSignalingManager.create_session(session_id,
               server: server_name,
               actor_id: "actor-1"
             )

    assert_receive {:fetch_session, ^session_id}
  end

  test "accepts bare session maps from injected trackers" do
    session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    manager_opts = [
      name: server_name,
      session_tracker: BareSessionTrackerStub,
      media_manager: MediaManagerStub,
      session_ttl_ms: 5_000
    ]

    start_supervised!({WebRTCSignalingManager, manager_opts})

    assert {:ok,
            %{viewer_session_id: viewer_session_id, signaling_state: "offer_created", offer_sdp: "v=0\r\ndesktop-offer"}} =
             WebRTCSignalingManager.create_session(session_id,
               server: server_name,
               actor_id: "actor-1"
             )

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
             WebRTCSignalingManager.create_session(Ecto.UUID.generate(),
               server: server_name,
               actor_id: "actor-1"
             )
  end

  test "returns unavailable when the desktop media offer provider is disabled" do
    session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager, name: server_name, session_tracker: SessionTrackerStub, session_ttl_ms: 5_000}
    )

    assert {:error, "desktop media plane is not available"} =
             WebRTCSignalingManager.create_session(session_id,
               server: server_name,
               actor_id: "actor-1",
               offer_provider: false
             )
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core_elx, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core_elx, key, value)
  defp unique_server_name, do: :"remote_desktop_webrtc_core_test_#{System.unique_integer([:positive])}"

  defp valid_answer_sdp do
    """
    v=0
    o=- 0 0 IN IP4 127.0.0.1
    s=-
    t=0 0
    a=fingerprint:sha-256 AA:BB:CC:DD
    m=application 9 UDP/DTLS/SCTP webrtc-datachannel
    a=sctp-port:5000
    """
  end
end
