defmodule ServiceRadarAgentGateway.CameraMediaSessionTrackerTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.CameraMediaSessionTracker

  setup do
    previous_state =
      CameraMediaSessionTracker
      |> :sys.get_state()
      |> clear_sessions()

    :sys.replace_state(CameraMediaSessionTracker, fn state ->
      Map.put(state, :sessions, %{})
    end)

    on_exit(fn ->
      :telemetry.detach(telemetry_handler_id())

      CameraMediaSessionTracker
      |> :sys.get_state()
      |> clear_sessions()

      :sys.replace_state(CameraMediaSessionTracker, fn _state -> previous_state end)
    end)

    :ok = attach_telemetry_handler(self())

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

    assert_receive_telemetry(
      [:serviceradar, :camera_relay, :session, :opened],
      %{relay_boundary: "agent_gateway", relay_session_id: "relay-1", relay_status: "active"}
    )

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

    assert_receive_telemetry(
      [:serviceradar, :camera_relay, :session, :closed],
      %{relay_boundary: "agent_gateway", relay_session_id: "relay-1", relay_status: "active"}
    )

    assert CameraMediaSessionTracker.fetch_session("relay-1") == nil
  end

  test "marks a session closing and keeps counters moving during drain" do
    future_expiry = System.os_time(:second) + 60

    assert {:ok, session} =
             CameraMediaSessionTracker.open_session(%{
               relay_session_id: "relay-drain-1",
               media_ingest_id: "core-media-drain-1",
               agent_id: "agent-1",
               gateway_id: "gateway-1",
               partition_id: "default",
               camera_source_id: "camera-1",
               stream_profile_id: "main",
               lease_token: "lease-drain-1",
               lease_expires_at_unix: future_expiry
             })

    assert session.status == "active"
    assert session.close_reason == nil

    assert {:ok, closing} =
             CameraMediaSessionTracker.mark_closing("relay-drain-1", "core-media-drain-1", %{
               close_reason: "upstream relay drain"
             })

    assert closing.status == "closing"
    assert closing.close_reason == "upstream relay drain"

    assert_receive_telemetry(
      [:serviceradar, :camera_relay, :session, :closing],
      %{
        relay_boundary: "agent_gateway",
        relay_session_id: "relay-drain-1",
        relay_status: "closing",
        close_reason: "upstream relay drain"
      }
    )

    assert {:ok, updated} =
             CameraMediaSessionTracker.heartbeat("relay-drain-1", "core-media-drain-1", %{
               last_sequence: 8,
               sent_bytes: 21
             })

    assert updated.status == "closing"
    assert updated.last_sequence == 8
    assert updated.sent_bytes == 21
  end

  defp clear_sessions(state) do
    Map.put(state, :sessions, %{})
  end

  defp attach_telemetry_handler(test_pid) do
    :telemetry.attach_many(
      telemetry_handler_id(),
      [
        [:serviceradar, :camera_relay, :session, :opened],
        [:serviceradar, :camera_relay, :session, :closing],
        [:serviceradar, :camera_relay, :session, :closed]
      ],
      &__MODULE__.handle_telemetry_event/4,
      test_pid
    )
  end

  def handle_telemetry_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event, measurements, metadata})
  end

  defp assert_receive_telemetry(event, expected_metadata) do
    assert_receive {:telemetry_event, ^event, _measurements, metadata}

    Enum.each(expected_metadata, fn {key, value} ->
      assert Map.get(metadata, key) == value
    end)
  end

  defp telemetry_handler_id, do: {:camera_media_session_tracker_test, __MODULE__}
end
