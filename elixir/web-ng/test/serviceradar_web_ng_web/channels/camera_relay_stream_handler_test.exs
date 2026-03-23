defmodule ServiceRadarWebNGWeb.Channels.CameraRelayStreamHandlerTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Channels.CameraRelayStreamHandler

  test "pushes an initial relay snapshot and subsequent state changes" do
    relay_session_id = Ecto.UUID.generate()

    {:ok, session_agent} =
      Agent.start_link(fn ->
        %{
          id: relay_session_id,
          camera_source_id: Ecto.UUID.generate(),
          stream_profile_id: Ecto.UUID.generate(),
          status: :opening,
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
             "playback_state" => "pending"
           } = Jason.decode!(payload)

    Agent.update(session_agent, fn session ->
      %{session | status: :active, media_ingest_id: "core-media-1"}
    end)

    assert {:push, {:text, payload}, state} = CameraRelayStreamHandler.handle_info(:poll, state)

    assert %{
             "status" => "active",
             "playback_state" => "ready",
             "media_ingest_id" => "core-media-1"
           } = Jason.decode!(payload)

    Agent.update(session_agent, fn session -> %{session | status: :closed} end)

    assert {:stop, :normal, 1000, [{:text, payload}], _state} =
             CameraRelayStreamHandler.handle_info(:poll, state)

    assert %{"status" => "closed", "playback_state" => "closed"} = Jason.decode!(payload)
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

  test "forwards media chunks as websocket binary frames" do
    relay_session_id = Ecto.UUID.generate()
    scope = Scope.for_user(%{id: "viewer-1", email: "viewer@example.com", role: :viewer})

    fetcher = fn ^relay_session_id, _opts ->
      {:ok,
       %{
         id: relay_session_id,
         camera_source_id: Ecto.UUID.generate(),
         stream_profile_id: Ecto.UUID.generate(),
         status: :active,
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

    assert {:push, {:binary, frame}, ^state} =
             CameraRelayStreamHandler.handle_info(
               {:camera_relay_chunk,
                %{
                  relay_session_id: relay_session_id,
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
end
