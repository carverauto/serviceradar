defmodule ServiceRadarAgentGateway.DesktopMediaSessionTrackerTest do
  use ExUnit.Case, async: false

  import ServiceRadarAgentGateway.TestSupport.MediaSessionTrackerTelemetry, only: [assert_receive_telemetry: 2]

  alias ServiceRadarAgentGateway.DesktopMediaSessionTracker
  alias ServiceRadarAgentGateway.TestSupport.MediaSessionTrackerTelemetry

  @moduletag :requires_app

  setup do
    previous_agent_limit =
      Application.get_env(:serviceradar_agent_gateway, :desktop_media_max_sessions_per_agent)

    previous_gateway_limit =
      Application.get_env(:serviceradar_agent_gateway, :desktop_media_max_sessions_per_gateway)

    previous_state =
      DesktopMediaSessionTracker
      |> :sys.get_state()
      |> clear_sessions()

    :sys.replace_state(DesktopMediaSessionTracker, fn state ->
      Map.put(state, :sessions, %{})
    end)

    on_exit(fn ->
      :telemetry.detach(telemetry_handler_id())

      DesktopMediaSessionTracker
      |> :sys.get_state()
      |> clear_sessions()

      :sys.replace_state(DesktopMediaSessionTracker, fn _state -> previous_state end)

      restore_env(:desktop_media_max_sessions_per_agent, previous_agent_limit)
      restore_env(:desktop_media_max_sessions_per_gateway, previous_gateway_limit)
    end)

    :ok = MediaSessionTrackerTelemetry.attach(telemetry_handler_id(), telemetry_events(), self())

    :ok
  end

  # credo:disable-for-next-line Jump.CredoChecks.TooManyAssertions
  test "opens a route-bound session and tracks frame, ack, heartbeat, and close state" do
    future_expiry = System.os_time(:second) + 60
    renewed_expiry = future_expiry + 30

    assert {:ok, session} =
             DesktopMediaSessionTracker.open_session(%{
               desktop_session_id: "desktop-1",
               media_session_id: "media-1",
               media_ingest_id: "ingest-1",
               agent_id: "agent-1",
               gateway_id: "gateway-1",
               partition_id: "default",
               target_id: "target-1",
               route_id: "route-1",
               lease_token: "lease-1",
               initial_credit_bytes: 4096,
               max_chunk_bytes: 1024,
               max_ack_credit_bytes: 300,
               lease_expires_at_unix: future_expiry
             })

    assert session.media_session_id == "media-1"
    assert session.media_ingest_id == "ingest-1"
    assert session.initial_credit_bytes == 4096
    assert session.max_chunk_bytes == 1024
    assert session.max_ack_credit_bytes == 300
    assert session.lease_expires_at_unix == future_expiry

    assert_receive_telemetry(
      [:serviceradar, :desktop_media, :session, :opened],
      %{relay_boundary: "agent_gateway", desktop_session_id: "desktop-1", status: "active"}
    )

    assert {:ok, framed} =
             DesktopMediaSessionTracker.record_frame("desktop-1", "media-1", "agent-1", %{
               sequence: 7,
               credit_cost: 512
             })

    assert framed.last_sequence == 7
    assert framed.sent_bytes == 512

    assert {:ok, acked} =
             DesktopMediaSessionTracker.apply_ack("desktop-1", "media-1", %{
               last_accepted_sequence: 6,
               credit_bytes: 256,
               quality_level: 80,
               pause: true
             })

    assert acked.last_accepted_sequence == 6
    assert acked.received_credit_bytes == 256
    assert acked.quality_level == 80
    assert acked.paused == true

    assert {:ok, resumed} =
             DesktopMediaSessionTracker.apply_ack("desktop-1", "media-1", %{
               last_accepted_sequence: 7,
               credit_bytes: 128,
               resume: true
             })

    assert resumed.last_accepted_sequence == 7
    assert resumed.received_credit_bytes == 384
    assert resumed.quality_level == 80
    assert resumed.paused == false

    assert {:ok, capped} =
             DesktopMediaSessionTracker.apply_ack("desktop-1", "media-1", %{
               last_accepted_sequence: 8,
               credit_bytes: 999
             })

    assert capped.last_accepted_sequence == 8
    assert capped.received_credit_bytes == 684
    assert capped.quality_level == 80

    assert {:ok, heartbeated} =
             DesktopMediaSessionTracker.heartbeat("desktop-1", "media-1", "agent-1", %{
               last_sequence: 8,
               sent_bytes: 1024,
               received_credit_bytes: 384,
               viewer_count: 1,
               lease_expires_at_unix: renewed_expiry
             })

    assert heartbeated.last_sequence == 8
    assert heartbeated.sent_bytes == 1024
    assert heartbeated.viewer_count == 1
    assert heartbeated.lease_expires_at_unix == renewed_expiry

    assert :ok = DesktopMediaSessionTracker.close_session("desktop-1", "media-1", "agent-1", %{})

    assert_receive_telemetry(
      [:serviceradar, :desktop_media, :session, :closed],
      %{relay_boundary: "agent_gateway", desktop_session_id: "desktop-1", status: "active"}
    )

    assert DesktopMediaSessionTracker.fetch_session("desktop-1") == nil
  end

  test "rejects frame, heartbeat, and close mutations from the wrong agent" do
    assert {:ok, _session} =
             DesktopMediaSessionTracker.open_session(%{
               desktop_session_id: "desktop-owner-1",
               media_session_id: "media-owner-1",
               media_ingest_id: "ingest-owner-1",
               agent_id: "agent-owner",
               gateway_id: "gateway-1",
               partition_id: "default",
               target_id: "target-1",
               route_id: "route-1",
               lease_token: "lease-owner-1"
             })

    assert {:error, :agent_id_mismatch} =
             DesktopMediaSessionTracker.record_frame("desktop-owner-1", "media-owner-1", "agent-other", %{
               sequence: 1,
               credit_cost: 1
             })

    assert {:error, :agent_id_mismatch} =
             DesktopMediaSessionTracker.heartbeat("desktop-owner-1", "media-owner-1", "agent-other", %{})

    assert {:error, :agent_id_mismatch} =
             DesktopMediaSessionTracker.close_session("desktop-owner-1", "media-owner-1", "agent-other", %{})

    assert {:ok, _session} =
             DesktopMediaSessionTracker.fetch_session("desktop-owner-1", "agent-owner")
  end

  test "rejects mutations bound to a different media session" do
    assert {:ok, _session} =
             DesktopMediaSessionTracker.open_session(%{
               desktop_session_id: "desktop-media-check-1",
               media_session_id: "media-owner-1",
               media_ingest_id: "ingest-owner-1",
               agent_id: "agent-owner",
               gateway_id: "gateway-1",
               partition_id: "default",
               target_id: "target-1",
               route_id: "route-1",
               lease_token: "lease-owner-1"
             })

    assert {:error, :media_session_mismatch} =
             DesktopMediaSessionTracker.record_frame(
               "desktop-media-check-1",
               "media-other",
               "agent-owner",
               %{sequence: 1, credit_cost: 1}
             )

    assert {:error, :media_ingest_mismatch} =
             DesktopMediaSessionTracker.record_frame(
               "desktop-media-check-1",
               "media-owner-1",
               "agent-owner",
               %{media_ingest_id: "ingest-other", sequence: 1, credit_cost: 1}
             )

    assert {:error, :media_session_mismatch} =
             DesktopMediaSessionTracker.apply_ack("desktop-media-check-1", "media-other", %{
               last_accepted_sequence: 1,
               credit_bytes: 1
             })

    assert {:error, :media_ingest_mismatch} =
             DesktopMediaSessionTracker.apply_ack("desktop-media-check-1", "media-owner-1", %{
               media_ingest_id: "ingest-other",
               last_accepted_sequence: 1,
               credit_bytes: 1
             })

    assert {:ok, session} =
             DesktopMediaSessionTracker.fetch_session("desktop-media-check-1", "agent-owner")

    assert session.last_sequence == 0
    assert session.sent_bytes == 0
    assert session.last_accepted_sequence == 0
    assert session.received_credit_bytes == 0
  end

  test "moves to closing when an ack carries a close reason" do
    assert {:ok, _session} =
             DesktopMediaSessionTracker.open_session(%{
               desktop_session_id: "desktop-close-ack-1",
               media_session_id: "media-close-ack-1",
               media_ingest_id: "ingest-close-ack-1",
               agent_id: "agent-1",
               gateway_id: "gateway-1",
               partition_id: "default",
               target_id: "target-1",
               route_id: "route-1",
               lease_token: "lease-close-ack-1"
             })

    assert {:ok, closing} =
             DesktopMediaSessionTracker.apply_ack("desktop-close-ack-1", "media-close-ack-1", %{
               close_reason: "browser closed"
             })

    assert closing.status == "closing"
    assert closing.close_reason == "browser closed"

    assert {:error, :session_closing} =
             DesktopMediaSessionTracker.record_frame("desktop-close-ack-1", "media-close-ack-1", "agent-1", %{
               sequence: 1,
               credit_cost: 1
             })

    assert {:error, :session_closing} =
             DesktopMediaSessionTracker.apply_ack("desktop-close-ack-1", "media-close-ack-1", %{
               last_accepted_sequence: 1,
               credit_bytes: 1
             })

    assert {:error, :session_closing} =
             DesktopMediaSessionTracker.heartbeat("desktop-close-ack-1", "media-close-ack-1", "agent-1", %{})

    assert :ok = DesktopMediaSessionTracker.close_session("desktop-close-ack-1", "media-close-ack-1", "agent-1", %{})
  end

  test "rejects frame, acknowledgement, and heartbeat mutations after lease expiry" do
    expired_at = System.os_time(:second) - 60

    assert {:ok, _session} =
             DesktopMediaSessionTracker.open_session(%{
               desktop_session_id: "desktop-expired-1",
               media_session_id: "media-expired-1",
               media_ingest_id: "ingest-expired-1",
               agent_id: "agent-1",
               gateway_id: "gateway-1",
               partition_id: "default",
               target_id: "target-1",
               route_id: "route-1",
               lease_token: "lease-expired-1",
               lease_expires_at_unix: expired_at
             })

    assert {:error, :session_expired} =
             DesktopMediaSessionTracker.record_frame("desktop-expired-1", "media-expired-1", "agent-1", %{
               sequence: 1,
               credit_cost: 1
             })

    assert {:error, :session_expired} =
             DesktopMediaSessionTracker.apply_ack("desktop-expired-1", "media-expired-1", %{
               media_ingest_id: "ingest-expired-1",
               last_accepted_sequence: 1,
               credit_bytes: 1
             })

    assert {:error, :session_expired} =
             DesktopMediaSessionTracker.heartbeat("desktop-expired-1", "media-expired-1", "agent-1", %{
               media_ingest_id: "ingest-expired-1",
               lease_expires_at_unix: System.os_time(:second) + 60
             })

    assert :ok = DesktopMediaSessionTracker.close_session("desktop-expired-1", "media-expired-1", "agent-1", %{})
  end

  test "sweeps expired sessions and frees gateway capacity" do
    Application.put_env(:serviceradar_agent_gateway, :desktop_media_max_sessions_per_gateway, 1)

    expired_at = System.os_time(:second) - 60

    assert {:ok, _expired} =
             DesktopMediaSessionTracker.open_session(%{
               desktop_session_id: "desktop-reaper-expired-1",
               media_session_id: "media-reaper-expired-1",
               media_ingest_id: "ingest-reaper-expired-1",
               agent_id: "agent-reaper-1",
               gateway_id: "gateway-1",
               partition_id: "default",
               target_id: "target-reaper-expired-1",
               route_id: "route-reaper-expired-1",
               lease_token: "lease-reaper-expired-1",
               lease_expires_at_unix: expired_at
             })

    assert {:ok, active} =
             DesktopMediaSessionTracker.open_session(session_attrs("desktop-reaper-active-1", "agent-reaper-2"))

    assert active.desktop_session_id == "desktop-reaper-active-1"
    assert DesktopMediaSessionTracker.fetch_session("desktop-reaper-expired-1") == nil
    assert {:ok, 0} = DesktopMediaSessionTracker.sweep_expired_sessions()

    assert_receive_telemetry(
      [:serviceradar, :desktop_media, :session, :expired],
      %{
        relay_boundary: "agent_gateway",
        desktop_session_id: "desktop-reaper-expired-1",
        reason: "lease_expired"
      }
    )
  end

  test "enforces per-agent and per-gateway desktop media session limits" do
    Application.put_env(:serviceradar_agent_gateway, :desktop_media_max_sessions_per_agent, 1)
    Application.put_env(:serviceradar_agent_gateway, :desktop_media_max_sessions_per_gateway, 2)

    assert {:ok, _session} =
             DesktopMediaSessionTracker.open_session(session_attrs("desktop-limit-1", "agent-limit-1"))

    assert {:error, {:limit_exceeded, :agent, 1}} =
             DesktopMediaSessionTracker.open_session(session_attrs("desktop-limit-2", "agent-limit-1"))

    assert_receive_telemetry(
      [:serviceradar, :desktop_media, :session, :saturation_denied],
      %{relay_boundary: "agent_gateway", desktop_session_id: "desktop-limit-2"}
    )

    assert {:ok, _session} =
             DesktopMediaSessionTracker.open_session(session_attrs("desktop-limit-3", "agent-limit-2"))

    assert {:error, {:limit_exceeded, :gateway, 2}} =
             DesktopMediaSessionTracker.open_session(session_attrs("desktop-limit-4", "agent-limit-3"))
  end

  defp session_attrs(desktop_session_id, agent_id) do
    %{
      desktop_session_id: desktop_session_id,
      media_session_id: "media-#{desktop_session_id}",
      media_ingest_id: "ingest-#{desktop_session_id}",
      agent_id: agent_id,
      gateway_id: "gateway-1",
      partition_id: "default",
      target_id: "target-#{desktop_session_id}",
      route_id: "route-#{desktop_session_id}",
      lease_token: "lease-#{desktop_session_id}"
    }
  end

  defp clear_sessions(state) do
    Map.put(state, :sessions, %{})
  end

  defp telemetry_events do
    [
      [:serviceradar, :desktop_media, :session, :opened],
      [:serviceradar, :desktop_media, :session, :closing],
      [:serviceradar, :desktop_media, :session, :closed],
      [:serviceradar, :desktop_media, :session, :expired],
      [:serviceradar, :desktop_media, :session, :saturation_denied]
    ]
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_agent_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_agent_gateway, key, value)

  defp telemetry_handler_id, do: {:desktop_media_session_tracker_test, __MODULE__}
end
