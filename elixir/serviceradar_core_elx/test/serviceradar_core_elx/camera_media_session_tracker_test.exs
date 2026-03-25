defmodule ServiceRadarCoreElx.CameraMediaSessionTrackerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Camera.RelayPubSub
  alias ServiceRadarCoreElx.CameraMediaSessionTracker
  alias ServiceRadarCoreElx.CameraRelay.PipelineManager
  alias ServiceRadarCoreElx.CameraRelay.ViewerRegistry

  defmodule RelaySessionLifecycleStub do
    @moduledoc false
    def activate_session(relay_session_id, media_ingest_id, attrs, opts) do
      send(opts[:test_pid], {:activate_session, relay_session_id, media_ingest_id, attrs})
      {:ok, %{id: relay_session_id, media_ingest_id: media_ingest_id}}
    end

    def heartbeat_session(relay_session_id, media_ingest_id, attrs, opts) do
      send(opts[:test_pid], {:heartbeat_session, relay_session_id, media_ingest_id, attrs})
      {:ok, %{id: relay_session_id, media_ingest_id: media_ingest_id}}
    end

    def close_session(relay_session_id, media_ingest_id, attrs, opts) do
      send(opts[:test_pid], {:close_session, relay_session_id, media_ingest_id, attrs})

      {:ok,
       %{
         id: relay_session_id,
         media_ingest_id: media_ingest_id,
         close_reason:
           Keyword.get(opts, :persisted_close_reason) || Map.get(attrs, :close_reason) ||
             "viewer idle timeout",
         failure_reason: Map.get(attrs, :failure_reason)
       }}
    end
  end

  setup do
    previous_state =
      CameraMediaSessionTracker
      |> :sys.get_state()
      |> clear_tracker_sessions()

    test_pid = self()

    :sys.replace_state(CameraMediaSessionTracker, fn state ->
      state
      |> Map.put(:sessions, %{})
      |> Map.put(:sync_module, RelaySessionLifecycleStub)
      |> Map.put(:sync_opts, test_pid: test_pid)
    end)

    on_exit(fn ->
      :telemetry.detach(telemetry_handler_id(test_pid))

      CameraMediaSessionTracker
      |> :sys.get_state()
      |> clear_tracker_sessions()

      :sys.replace_state(CameraMediaSessionTracker, fn _state -> previous_state end)
    end)

    :ok = attach_telemetry_handler(test_pid)

    :ok
  end

  test "opens, tracks, heartbeats, and closes a core relay session" do
    relay_session_id = unique_relay_session_id()
    viewer_id = unique_viewer_id()
    :ok = RelayPubSub.subscribe(relay_session_id)
    :ok = RelayPubSub.subscribe_viewer(relay_session_id, viewer_id)
    :ok = RelayPubSub.viewer_join(relay_session_id, viewer_id)
    _ = :sys.get_state(ViewerRegistry)

    assert {:ok, session} =
             CameraMediaSessionTracker.open_session(%{
               relay_session_id: relay_session_id,
               agent_id: "agent-1",
               gateway_id: "gateway-1",
               camera_source_id: "camera-1",
               stream_profile_id: "main"
             })

    assert String.starts_with?(session.media_ingest_id, "core-media-")

    assert_receive {:activate_session, ^relay_session_id, media_ingest_id,
                    %{lease_expires_at_unix: lease_expires_at_unix, viewer_count: 1}}

    assert_receive_telemetry(
      [:serviceradar, :camera_relay, :session, :opened],
      %{relay_boundary: "core_elx", relay_session_id: relay_session_id, viewer_count: 1},
      %{viewer_count: 1}
    )

    assert_receive {:camera_relay_state,
                    %{
                      relay_session_id: ^relay_session_id,
                      status: "active",
                      playback_state: "ready",
                      preferred_playback_transport: "websocket_h264_annexb_webcodecs",
                      available_playback_transports: [
                        "websocket_h264_annexb_webcodecs",
                        "websocket_h264_annexb_jmuxer_mse"
                      ],
                      termination_kind: nil,
                      viewer_count: 1
                    }}

    assert media_ingest_id == session.media_ingest_id
    assert is_integer(lease_expires_at_unix)

    assert {:ok, updated} =
             CameraMediaSessionTracker.record_chunk(session.relay_session_id, session.media_ingest_id, %{
               sequence: 7,
               codec: "h264",
               payload_format: "annexb",
               payload: <<1, 2, 3, 4>>
             })

    assert updated.last_sequence == 7
    assert updated.sent_bytes == 4

    assert_receive {:camera_relay_viewer_chunk,
                    %{
                      relay_session_id: ^relay_session_id,
                      viewer_id: ^viewer_id,
                      sequence: 7,
                      payload: <<1, 2, 3, 4>>
                    }}

    :ok = RelayPubSub.viewer_leave(relay_session_id, viewer_id)
    _ = :sys.get_state(ViewerRegistry)

    assert_receive_telemetry(
      [:serviceradar, :camera_relay, :session, :viewer_count_changed],
      %{
        relay_boundary: "core_elx",
        relay_session_id: relay_session_id,
        previous_viewer_count: 1,
        viewer_count: 0
      },
      %{viewer_count: 0}
    )

    expected_heartbeat_attrs = %{lease_expires_at_unix: _, viewer_count: 0}
    assert_receive {:heartbeat_session, ^relay_session_id, ^media_ingest_id, ^expected_heartbeat_attrs}

    assert_receive {:camera_relay_state, %{relay_session_id: ^relay_session_id, viewer_count: 0, termination_kind: nil}}

    assert {:ok, heartbeated} =
             CameraMediaSessionTracker.heartbeat(session.relay_session_id, session.media_ingest_id, %{
               last_sequence: 8,
               sent_bytes: 20
             })

    assert heartbeated.last_sequence == 8
    assert heartbeated.sent_bytes == 20

    assert_receive {:heartbeat_session, ^relay_session_id, ^media_ingest_id,
                    %{lease_expires_at_unix: renewed_lease, viewer_count: 0}}

    assert is_integer(renewed_lease)

    assert :ok = CameraMediaSessionTracker.close_session(session.relay_session_id, session.media_ingest_id)
    assert_receive {:close_session, ^relay_session_id, ^media_ingest_id, %{close_reason: nil, viewer_count: 0}}

    assert_receive_telemetry(
      [:serviceradar, :camera_relay, :session, :closed],
      %{relay_boundary: "core_elx", relay_session_id: relay_session_id, termination_kind: "viewer_idle", viewer_count: 0},
      %{viewer_count: 0}
    )

    assert_receive {:camera_relay_state,
                    %{
                      relay_session_id: ^relay_session_id,
                      status: "closed",
                      playback_state: "closed",
                      preferred_playback_transport: "websocket_h264_annexb_webcodecs",
                      termination_kind: "viewer_idle",
                      viewer_count: 0,
                      close_reason: "viewer idle timeout",
                      failure_reason: nil
                    }}
  end

  test "rejects duplicate relay session ids" do
    relay_session_id = unique_relay_session_id()

    assert {:ok, _session} =
             CameraMediaSessionTracker.open_session(%{
               relay_session_id: relay_session_id,
               agent_id: "agent-1",
               gateway_id: "gateway-1",
               camera_source_id: "camera-1",
               stream_profile_id: "main"
             })

    assert {:error, :already_exists} =
             CameraMediaSessionTracker.open_session(%{
               relay_session_id: relay_session_id,
               agent_id: "agent-1",
               gateway_id: "gateway-1",
               camera_source_id: "camera-1",
               stream_profile_id: "main"
             })
  end

  test "uses a provided media ingest id when reopening a relay session" do
    relay_session_id = unique_relay_session_id()
    media_ingest_id = "core-media-reused"

    assert {:ok, session} =
             CameraMediaSessionTracker.open_session(%{
               relay_session_id: relay_session_id,
               media_ingest_id: media_ingest_id,
               agent_id: "agent-1",
               gateway_id: "gateway-1",
               camera_source_id: "camera-1",
               stream_profile_id: "main"
             })

    assert session.media_ingest_id == media_ingest_id

    expected_activate_attrs = %{lease_expires_at_unix: _, viewer_count: 0}
    assert_receive {:activate_session, ^relay_session_id, ^media_ingest_id, ^expected_activate_attrs}
  end

  test "marks an in-memory relay session closing before terminal teardown" do
    relay_session_id = unique_relay_session_id()
    :ok = RelayPubSub.subscribe(relay_session_id)

    assert {:ok, session} =
             CameraMediaSessionTracker.open_session(%{
               relay_session_id: relay_session_id,
               agent_id: "agent-1",
               gateway_id: "gateway-1",
               camera_source_id: "camera-1",
               stream_profile_id: "main"
             })

    assert_receive {:camera_relay_state, %{relay_session_id: ^relay_session_id, status: "active", termination_kind: nil}}

    :ok =
      CameraMediaSessionTracker.mark_closing(relay_session_id, %{
        close_reason: "viewer idle timeout",
        viewer_count: 0
      })

    assert_receive_telemetry(
      [:serviceradar, :camera_relay, :session, :closing],
      %{relay_boundary: "core_elx", relay_session_id: relay_session_id, termination_kind: "viewer_idle", viewer_count: 0},
      %{viewer_count: 0}
    )

    assert_receive {:camera_relay_state,
                    %{
                      relay_session_id: ^relay_session_id,
                      status: "closing",
                      playback_state: "closing",
                      termination_kind: "viewer_idle",
                      close_reason: "viewer idle timeout",
                      viewer_count: 0
                    }}

    media_ingest_id = session.media_ingest_id

    assert :ok =
             CameraMediaSessionTracker.close_session(
               session.relay_session_id,
               session.media_ingest_id,
               %{reason: "camera relay drain acknowledged"}
             )

    assert_receive {:close_session, ^relay_session_id, ^media_ingest_id,
                    %{close_reason: "camera relay drain acknowledged", viewer_count: 0}}
  end

  test "accepts late heartbeats for a closing relay session without lifecycle churn" do
    relay_session_id = unique_relay_session_id()
    :ok = RelayPubSub.subscribe(relay_session_id)

    assert {:ok, session} =
             CameraMediaSessionTracker.open_session(%{
               relay_session_id: relay_session_id,
               agent_id: "agent-1",
               gateway_id: "gateway-1",
               camera_source_id: "camera-1",
               stream_profile_id: "main"
             })

    assert_receive {:activate_session, ^relay_session_id, media_ingest_id, _attrs}
    assert_receive {:camera_relay_state, %{relay_session_id: ^relay_session_id, status: "active", termination_kind: nil}}

    :ok =
      CameraMediaSessionTracker.mark_closing(relay_session_id, %{
        close_reason: "viewer closed device details",
        viewer_count: 0
      })

    assert_receive {:camera_relay_state,
                    %{
                      relay_session_id: ^relay_session_id,
                      status: "closing",
                      playback_state: "closing",
                      termination_kind: "manual_stop",
                      close_reason: "viewer closed device details"
                    }}

    assert {:ok, updated} =
             CameraMediaSessionTracker.heartbeat(
               relay_session_id,
               media_ingest_id,
               %{last_sequence: 9, sent_bytes: 42}
             )

    assert updated.last_sequence == 9
    assert updated.sent_bytes == 42
    assert updated.status == "closing"

    refute_receive {:heartbeat_session, ^relay_session_id, ^media_ingest_id, _attrs}, 50

    assert_receive {:camera_relay_state,
                    %{
                      relay_session_id: ^relay_session_id,
                      status: "closing",
                      playback_state: "closing"
                    }}

    assert :ok =
             CameraMediaSessionTracker.close_session(
               session.relay_session_id,
               session.media_ingest_id,
               %{reason: "viewer closed device details"}
             )
  end

  test "drops late media chunks for a closing relay session" do
    relay_session_id = unique_relay_session_id()
    viewer_id = unique_viewer_id()
    :ok = RelayPubSub.subscribe(relay_session_id)
    :ok = RelayPubSub.subscribe_viewer(relay_session_id, viewer_id)
    :ok = RelayPubSub.viewer_join(relay_session_id, viewer_id)
    _ = :sys.get_state(ViewerRegistry)

    assert {:ok, session} =
             CameraMediaSessionTracker.open_session(%{
               relay_session_id: relay_session_id,
               agent_id: "agent-1",
               gateway_id: "gateway-1",
               camera_source_id: "camera-1",
               stream_profile_id: "main"
             })

    assert_receive {:activate_session, ^relay_session_id, media_ingest_id, _attrs}
    assert_receive {:camera_relay_state, %{relay_session_id: ^relay_session_id, status: "active", termination_kind: nil}}

    :ok =
      CameraMediaSessionTracker.mark_closing(relay_session_id, %{
        close_reason: "viewer closed device details",
        viewer_count: 0
      })

    assert_receive {:camera_relay_state,
                    %{relay_session_id: ^relay_session_id, status: "closing", termination_kind: "manual_stop"}}

    assert {:ok, updated} =
             CameraMediaSessionTracker.record_chunk(relay_session_id, media_ingest_id, %{
               sequence: 10,
               codec: "h264",
               payload_format: "annexb",
               payload: <<5, 6, 7, 8>>
             })

    assert updated.last_sequence == 10
    assert updated.sent_bytes == 4
    assert updated.status == "closing"

    refute_receive {:camera_relay_viewer_chunk, %{relay_session_id: ^relay_session_id, viewer_id: ^viewer_id}},
                   50

    assert :ok =
             CameraMediaSessionTracker.close_session(
               session.relay_session_id,
               session.media_ingest_id,
               %{reason: "viewer closed device details"}
             )
  end

  test "broadcasts the persisted close reason when drain acknowledgement closes a requested shutdown" do
    relay_session_id = unique_relay_session_id()
    :ok = RelayPubSub.subscribe(relay_session_id)
    test_pid = self()

    :sys.replace_state(CameraMediaSessionTracker, fn state ->
      Map.put(state, :sync_opts, test_pid: test_pid, persisted_close_reason: "viewer idle timeout")
    end)

    assert {:ok, session} =
             CameraMediaSessionTracker.open_session(%{
               relay_session_id: relay_session_id,
               agent_id: "agent-1",
               gateway_id: "gateway-1",
               camera_source_id: "camera-1",
               stream_profile_id: "main"
             })

    assert_receive {:activate_session, ^relay_session_id, media_ingest_id, _attrs}
    assert_receive {:camera_relay_state, %{relay_session_id: ^relay_session_id, status: "active", termination_kind: nil}}

    :ok =
      CameraMediaSessionTracker.mark_closing(relay_session_id, %{
        close_reason: "viewer idle timeout",
        viewer_count: 0
      })

    assert_receive {:camera_relay_state,
                    %{
                      relay_session_id: ^relay_session_id,
                      status: "closing",
                      termination_kind: "viewer_idle",
                      close_reason: "viewer idle timeout"
                    }}

    assert :ok =
             CameraMediaSessionTracker.close_session(
               session.relay_session_id,
               session.media_ingest_id,
               %{reason: "camera relay drain acknowledged"}
             )

    assert_receive {:close_session, ^relay_session_id, ^media_ingest_id,
                    %{close_reason: "camera relay drain acknowledged", viewer_count: 0}}

    assert_receive {:camera_relay_state,
                    %{
                      relay_session_id: ^relay_session_id,
                      status: "closed",
                      playback_state: "closed",
                      termination_kind: "viewer_idle",
                      close_reason: "viewer idle timeout"
                    }}
  end

  defp clear_tracker_sessions(state) do
    state
    |> Map.get(:sessions, %{})
    |> Map.keys()
    |> Enum.each(&PipelineManager.close_session/1)

    Map.put(state, :sessions, %{})
  end

  defp unique_relay_session_id do
    "relay-#{System.unique_integer([:positive])}"
  end

  defp unique_viewer_id do
    "viewer-#{System.unique_integer([:positive])}"
  end

  defp attach_telemetry_handler(test_pid) do
    :telemetry.attach_many(
      telemetry_handler_id(test_pid),
      [
        [:serviceradar, :camera_relay, :session, :opened],
        [:serviceradar, :camera_relay, :session, :viewer_count_changed],
        [:serviceradar, :camera_relay, :session, :closing],
        [:serviceradar, :camera_relay, :session, :closed],
        [:serviceradar, :camera_relay, :session, :failed]
      ],
      &__MODULE__.handle_telemetry_event/4,
      test_pid
    )
  end

  def handle_telemetry_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event, measurements, metadata})
  end

  defp assert_receive_telemetry(event, expected_metadata, expected_measurements) do
    assert_receive {:telemetry_event, ^event, measurements, metadata}

    Enum.each(expected_metadata, fn {key, value} ->
      assert Map.get(metadata, key) == value
    end)

    Enum.each(expected_measurements, fn {key, value} ->
      assert Map.get(measurements, key) == value
    end)
  end

  defp telemetry_handler_id(test_pid), do: {:camera_media_session_tracker_test, test_pid}
end
