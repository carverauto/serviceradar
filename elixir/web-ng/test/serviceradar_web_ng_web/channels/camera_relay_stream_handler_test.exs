defmodule ServiceRadarWebNGWeb.Channels.CameraRelayStreamHandlerTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Channels.CameraRelayStreamHandler

  setup do
    previous_enabled = Application.get_env(:serviceradar_web_ng, :camera_relay_webrtc_enabled)
    previous_ice_servers = Application.get_env(:serviceradar_web_ng, :camera_relay_webrtc_ice_servers)

    Application.put_env(:serviceradar_web_ng, :camera_relay_webrtc_enabled, true)
    Application.put_env(:serviceradar_web_ng, :camera_relay_webrtc_ice_servers, [%{urls: ["stun:stun.example.com:3478"]}])

    on_exit(fn ->
      if is_nil(previous_enabled) do
        Application.delete_env(:serviceradar_web_ng, :camera_relay_webrtc_enabled)
      else
        Application.put_env(:serviceradar_web_ng, :camera_relay_webrtc_enabled, previous_enabled)
      end

      if is_nil(previous_ice_servers) do
        Application.delete_env(:serviceradar_web_ng, :camera_relay_webrtc_ice_servers)
      else
        Application.put_env(:serviceradar_web_ng, :camera_relay_webrtc_ice_servers, previous_ice_servers)
      end
    end)

    :ok
  end

  test "pushes an initial relay snapshot and subsequent state changes" do
    relay_session_id = Ecto.UUID.generate()

    {:ok, session_agent} =
      Agent.start_link(fn ->
        %{
          id: relay_session_id,
          camera_source_id: Ecto.UUID.generate(),
          stream_profile_id: Ecto.UUID.generate(),
          status: :opening,
          viewer_count: 0,
          media_ingest_id: nil,
          close_reason: nil,
          failure_reason: nil,
          lease_expires_at: DateTime.from_unix!(1_800_000_000),
          updated_at: DateTime.from_unix!(1_800_000_000)
        }
      end)

    fetcher = fn ^relay_session_id, _opts ->
      {:ok, Agent.get(session_agent, & &1)}
    end

    scope = Scope.for_user(%{id: "viewer-1", email: "viewer@example.com", role: :viewer})

    assert {:push, {:text, payload}, state} =
             CameraRelayStreamHandler.init(
               relay_session_id: relay_session_id,
               scope: scope,
               fetcher: fetcher,
               poll_interval_ms: 10_000
             )

    assert %{
             "type" => "camera_relay_snapshot",
             "relay_session_id" => ^relay_session_id,
             "status" => "opening",
             "playback_state" => "pending",
             "preferred_playback_transport" => "websocket_h264_annexb_webcodecs",
             "available_playback_transports" => [
               "websocket_h264_annexb_webcodecs",
               "websocket_h264_annexb_jmuxer_mse"
             ],
             "playback_codec_hint" => "h264",
             "playback_container_hint" => "annexb",
             "webrtc_enabled" => true,
             "webrtc_playback_transport" => "membrane_webrtc",
             "webrtc_signaling_path" => webrtc_path,
             "webrtc_ice_servers" => [%{"urls" => ["stun:stun.example.com:3478"]}],
             "termination_kind" => nil,
             "viewer_count" => 0
           } = Jason.decode!(payload)

    assert webrtc_path == "/api/camera-relay-sessions/#{relay_session_id}/webrtc/session"

    Agent.update(session_agent, fn session ->
      %{session | status: :active, media_ingest_id: "core-media-1", viewer_count: 2}
    end)

    assert {:push, {:text, payload}, state} = CameraRelayStreamHandler.handle_info(:poll, state)

    assert %{
             "status" => "active",
             "playback_state" => "ready",
             "media_ingest_id" => "core-media-1",
             "viewer_count" => 2,
             "preferred_playback_transport" => "websocket_h264_annexb_webcodecs",
             "available_playback_transports" => [
               "websocket_h264_annexb_webcodecs",
               "websocket_h264_annexb_jmuxer_mse"
             ]
           } = Jason.decode!(payload)

    Agent.update(session_agent, fn session ->
      %{session | status: :closed, termination_kind: "viewer_idle", close_reason: "viewer idle timeout"}
    end)

    assert {:stop, :normal, 1000, [{:text, payload}], _state} =
             CameraRelayStreamHandler.handle_info(:poll, state)

    assert %{
             "status" => "closed",
             "playback_state" => "closed",
             "termination_kind" => "viewer_idle",
             "close_reason" => "viewer idle timeout",
             "preferred_playback_transport" => "websocket_h264_annexb_webcodecs"
           } = Jason.decode!(payload)
  end

  test "stops when the relay session no longer exists" do
    relay_session_id = Ecto.UUID.generate()
    scope = Scope.for_user(%{id: "viewer-1", email: "viewer@example.com", role: :viewer})

    fetcher = fn ^relay_session_id, _opts -> {:ok, nil} end

    assert {:stop, :normal, {1008, "relay session not found"}, _state} =
             CameraRelayStreamHandler.init(
               relay_session_id: relay_session_id,
               scope: scope,
               fetcher: fetcher,
               poll_interval_ms: 10_000
             )
  end

  test "stops on poll when an already-open relay session goes stale" do
    relay_session_id = Ecto.UUID.generate()
    scope = Scope.for_user(%{id: "viewer-1", email: "viewer@example.com", role: :viewer})

    {:ok, session_agent} =
      Agent.start_link(fn ->
        %{
          id: relay_session_id,
          camera_source_id: Ecto.UUID.generate(),
          stream_profile_id: Ecto.UUID.generate(),
          status: :active,
          viewer_count: 1,
          media_ingest_id: "core-media-stale-1",
          close_reason: nil,
          failure_reason: nil,
          lease_expires_at: DateTime.from_unix!(1_800_000_000),
          updated_at: DateTime.from_unix!(1_800_000_000)
        }
      end)

    fetcher = fn ^relay_session_id, _opts -> {:ok, Agent.get(session_agent, & &1)} end

    assert {:push, {:text, _payload}, state} =
             CameraRelayStreamHandler.init(
               relay_session_id: relay_session_id,
               scope: scope,
               fetcher: fetcher,
               poll_interval_ms: 10_000
             )

    Agent.update(session_agent, fn _session -> nil end)

    assert {:stop, :normal, {1008, "relay session not found"}, _state} =
             CameraRelayStreamHandler.handle_info(:poll, state)
  end

  test "forwards media chunks as websocket binary frames" do
    relay_session_id = Ecto.UUID.generate()
    viewer_id = Ecto.UUID.generate()
    scope = Scope.for_user(%{id: "viewer-1", email: "viewer@example.com", role: :viewer})

    fetcher = fn ^relay_session_id, _opts ->
      {:ok,
       %{
         id: relay_session_id,
         camera_source_id: Ecto.UUID.generate(),
         stream_profile_id: Ecto.UUID.generate(),
         status: :active,
         viewer_count: 1,
         media_ingest_id: "core-media-1",
         close_reason: nil,
         failure_reason: nil,
         lease_expires_at: DateTime.from_unix!(1_800_000_000),
         updated_at: DateTime.from_unix!(1_800_000_000)
       }}
    end

    assert {:push, {:text, _payload}, state} =
             CameraRelayStreamHandler.init(
               relay_session_id: relay_session_id,
               viewer_id: viewer_id,
               scope: scope,
               fetcher: fetcher,
               poll_interval_ms: 10_000
             )

    assert {:push, {:binary, frame}, ^state} =
             CameraRelayStreamHandler.handle_info(
               {:camera_relay_viewer_chunk,
                %{
                  relay_session_id: relay_session_id,
                  viewer_id: viewer_id,
                  media_ingest_id: "core-media-1",
                  sequence: 3,
                  pts: 33_000_000,
                  dts: 33_000_000,
                  keyframe: true,
                  codec: "h264",
                  payload_format: "annexb",
                  track_id: "video",
                  payload: <<1, 2, 3, 4>>
                }},
               state
             )

    assert <<
             "SRCM",
             1,
             flags,
             3::unsigned-big-64,
             33_000_000::signed-big-64,
             33_000_000::signed-big-64,
             codec_len::unsigned-big-16,
             payload_format_len::unsigned-big-16,
             track_len::unsigned-big-16,
             rest::binary
           >> = frame

    assert flags == 0x01
    assert codec_len == 4
    assert payload_format_len == 6
    assert track_len == 5

    assert <<
             "h264",
             "annexb",
             "video",
             1,
             2,
             3,
             4
           >> = rest
  end

  test "ignores regressive active snapshots after a relay enters closing" do
    relay_session_id = Ecto.UUID.generate()
    scope = Scope.for_user(%{id: "viewer-1", email: "viewer@example.com", role: :viewer})

    fetcher = fn ^relay_session_id, _opts ->
      {:ok,
       %{
         id: relay_session_id,
         camera_source_id: Ecto.UUID.generate(),
         stream_profile_id: Ecto.UUID.generate(),
         status: :active,
         viewer_count: 1,
         media_ingest_id: "core-media-1",
         close_reason: nil,
         failure_reason: nil,
         lease_expires_at: DateTime.from_unix!(1_800_000_000),
         updated_at: DateTime.from_unix!(1_800_000_000)
       }}
    end

    assert {:push, {:text, _payload}, state} =
             CameraRelayStreamHandler.init(
               relay_session_id: relay_session_id,
               scope: scope,
               fetcher: fetcher,
               poll_interval_ms: 10_000
             )

    assert {:push, {:text, payload}, state} =
             CameraRelayStreamHandler.handle_info(
               {:camera_relay_state,
                %{
                  relay_session_id: relay_session_id,
                  status: "closing",
                  playback_state: "closing",
                  termination_kind: "manual_stop",
                  viewer_count: 0,
                  close_reason: "viewer closed device details",
                  updated_at_unix: 1_800_000_010
                }},
               state
             )

    assert %{
             "status" => "closing",
             "playback_state" => "closing",
             "termination_kind" => "manual_stop",
             "preferred_playback_transport" => "websocket_h264_annexb_webcodecs"
           } = Jason.decode!(payload)

    assert {:ok, state} =
             CameraRelayStreamHandler.handle_info(
               {:camera_relay_state,
                %{
                  relay_session_id: relay_session_id,
                  status: "active",
                  playback_state: "ready",
                  viewer_count: 1,
                  updated_at_unix: 1_800_000_011
                }},
               state
             )
  end
end
