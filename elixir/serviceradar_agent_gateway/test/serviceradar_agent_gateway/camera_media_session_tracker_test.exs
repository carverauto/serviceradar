defmodule ServiceRadarAgentGateway.CameraMediaSessionTrackerTest do
  use ExUnit.Case, async: true

  alias ServiceRadarAgentGateway.CameraMediaSessionTracker

  setup do
    start_supervised!(CameraMediaSessionTracker)
    :ok
  end

  test "opens a session with upstream-provided ingest id and updates lifecycle state" do
    future_expiry = System.os_time(:second) + 60

    assert {:ok, session} =
             CameraMediaSessionTracker.open_session(%{
               relay_session_id: "relay-1",
               media_ingest_id: "core-media-1",
               agent_id: "agent-1",
               gateway_id: "gateway-1",
               partition_id: "default",
               camera_source_id: "camera-1",
               stream_profile_id: "main",
               lease_token: "lease-1",
               lease_expires_at_unix: future_expiry
             })

    assert session.media_ingest_id == "core-media-1"
    assert session.lease_expires_at_unix == future_expiry

    assert {:ok, updated} =
             CameraMediaSessionTracker.record_chunk("relay-1", "core-media-1", %{
               sequence: 5,
               payload: <<1, 2, 3>>
             })

    assert updated.last_sequence == 5
    assert updated.sent_bytes == 3

    assert {:ok, heartbeated} =
             CameraMediaSessionTracker.heartbeat("relay-1", "core-media-1", %{
               last_sequence: 6,
               sent_bytes: 10
             })

    assert heartbeated.last_sequence == 6
    assert heartbeated.sent_bytes == 10

    assert :ok = CameraMediaSessionTracker.close_session("relay-1", "core-media-1")
    assert CameraMediaSessionTracker.fetch_session("relay-1") == nil
  end
end
