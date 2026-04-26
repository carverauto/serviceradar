defmodule ServiceRadarAgentGateway.CameraMediaSessionTrackerTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.CameraMediaSessionTracker

  setup do
    previous_agent_limit =
      Application.get_env(:serviceradar_agent_gateway, :camera_relay_max_sessions_per_agent)

    previous_gateway_limit =
      Application.get_env(:serviceradar_agent_gateway, :camera_relay_max_sessions_per_gateway)

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

      restore_env(:camera_relay_max_sessions_per_agent, previous_agent_limit)
      restore_env(:camera_relay_max_sessions_per_gateway, previous_gateway_limit)
    end)

    :ok = attach_telemetry_handler(self())

    :ok
  end

  test "opens a session with upstream-provided ingest id and updates lifecycle state" do
    future_expiry = System.os_time(:second) + 60
    renewed_expiry = future_expiry + 30

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
               sent_bytes: 10,
               lease_expires_at_unix: renewed_expiry
             })

    assert heartbeated.last_sequence == 6
    assert heartbeated.sent_bytes == 10
    assert heartbeated.lease_expires_at_unix == renewed_expiry

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

  test "rejects relay mutations from a different agent" do
    assert {:ok, _session} =
             CameraMediaSessionTracker.open_session(%{
               relay_session_id: "relay-owner-check-1",
               media_ingest_id: "core-media-owner-check-1",
               agent_id: "agent-owner",
               gateway_id: "gateway-1",
               partition_id: "default",
               camera_source_id: "camera-1",
               stream_profile_id: "main",
               lease_token: "lease-owner-check-1"
             })

    assert {:error, :agent_id_mismatch} =
             CameraMediaSessionTracker.record_chunk(
               "relay-owner-check-1",
               "core-media-owner-check-1",
               "agent-other",
               %{sequence: 1, payload: <<1>>}
             )

    assert {:error, :agent_id_mismatch} =
             CameraMediaSessionTracker.heartbeat(
               "relay-owner-check-1",
               "core-media-owner-check-1",
               "agent-other",
               %{last_sequence: 2, sent_bytes: 4}
             )

    assert {:error, :agent_id_mismatch} =
             CameraMediaSessionTracker.close_session(
               "relay-owner-check-1",
               "core-media-owner-check-1",
               "agent-other",
               %{}
             )

    assert {:ok, _session} =
             CameraMediaSessionTracker.fetch_session("relay-owner-check-1", "agent-owner")
  end

  test "enforces the per-agent relay session limit" do
    Application.put_env(:serviceradar_agent_gateway, :camera_relay_max_sessions_per_agent, 1)
    Application.put_env(:serviceradar_agent_gateway, :camera_relay_max_sessions_per_gateway, 5)

    assert {:ok, _session} =
             CameraMediaSessionTracker.open_session(%{
               relay_session_id: "relay-agent-limit-1",
               media_ingest_id: "core-media-agent-limit-1",
               agent_id: "agent-limit-1",
               gateway_id: "gateway-1",
               partition_id: "default",
               camera_source_id: "camera-1",
               stream_profile_id: "main",
               lease_token: "lease-agent-limit-1"
             })

    assert {:error, {:limit_exceeded, :agent, 1}} =
             CameraMediaSessionTracker.open_session(%{
               relay_session_id: "relay-agent-limit-2",
               media_ingest_id: "core-media-agent-limit-2",
               agent_id: "agent-limit-1",
               gateway_id: "gateway-1",
               partition_id: "default",
               camera_source_id: "camera-2",
               stream_profile_id: "main",
               lease_token: "lease-agent-limit-2"
             })

    assert_receive_telemetry(
      [:serviceradar, :camera_relay, :session, :saturation_denied],
      %{relay_boundary: "agent_gateway", relay_session_id: "relay-agent-limit-2"}
    )
  end

  test "enforces the per-gateway relay session limit across agents" do
    Application.put_env(:serviceradar_agent_gateway, :camera_relay_max_sessions_per_agent, 5)
    Application.put_env(:serviceradar_agent_gateway, :camera_relay_max_sessions_per_gateway, 2)

    assert {:ok, _session} =
             CameraMediaSessionTracker.open_session(%{
               relay_session_id: "relay-gateway-limit-1",
               media_ingest_id: "core-media-gateway-limit-1",
               agent_id: "agent-limit-a",
               gateway_id: "gateway-1",
               partition_id: "default",
               camera_source_id: "camera-1",
               stream_profile_id: "main",
               lease_token: "lease-gateway-limit-1"
             })

    assert {:ok, _session} =
             CameraMediaSessionTracker.open_session(%{
               relay_session_id: "relay-gateway-limit-2",
               media_ingest_id: "core-media-gateway-limit-2",
               agent_id: "agent-limit-b",
               gateway_id: "gateway-1",
               partition_id: "default",
               camera_source_id: "camera-2",
               stream_profile_id: "main",
               lease_token: "lease-gateway-limit-2"
             })

    assert {:error, {:limit_exceeded, :gateway, 2}} =
             CameraMediaSessionTracker.open_session(%{
               relay_session_id: "relay-gateway-limit-3",
               media_ingest_id: "core-media-gateway-limit-3",
               agent_id: "agent-limit-c",
               gateway_id: "gateway-1",
               partition_id: "default",
               camera_source_id: "camera-3",
               stream_profile_id: "main",
               lease_token: "lease-gateway-limit-3"
             })
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
        [:serviceradar, :camera_relay, :session, :closed],
        [:serviceradar, :camera_relay, :session, :saturation_denied]
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

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_agent_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_agent_gateway, key, value)

  defp telemetry_handler_id, do: {:camera_media_session_tracker_test, __MODULE__}
end
