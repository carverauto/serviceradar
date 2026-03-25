defmodule ServiceRadarWebNGWeb.CameraRelayLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadar.Camera.Source, as: CameraSource
  alias ServiceRadar.Camera.StreamProfile, as: CameraStreamProfile
  alias ServiceRadarWebNG.AshTestHelpers
  alias ServiceRadarWebNG.Repo

  setup %{conn: conn} do
    user = AshTestHelpers.admin_user_fixture()
    previous_health_source = Application.get_env(:serviceradar_web_ng, :camera_relay_health_source)

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_health_source,
      ServiceRadarWebNG.CameraRelayHealthStub
    )

    on_exit(fn ->
      case previous_health_source do
        nil -> Application.delete_env(:serviceradar_web_ng, :camera_relay_health_source)
        module -> Application.put_env(:serviceradar_web_ng, :camera_relay_health_source, module)
      end
    end)

    %{conn: log_in_user(conn, user)}
  end

  test "renders camera relay operations page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/observability/camera-relays")

    assert html =~ "Camera Relay Operations"
    assert html =~ "Active Relay Sessions"
    assert html =~ "Recent Terminal Sessions"
    assert html =~ "Terminal Outcome Breakdown"
    assert html =~ "Viewer Idle"
    assert html =~ "Failures"
    assert html =~ "Active Relay Health Alerts"
    assert html =~ "Recent Relay Health Signals"
    assert html =~ "Camera Relay Failure Burst"
    assert html =~ "Camera relay session failed during request_open: agent_offline"
  end

  test "renders observability drill-down links for relay rows", %{conn: conn} do
    device_uid = "camera-relay-live-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: device_uid,
        type_id: 7,
        hostname: "camera-relay-host",
        vendor_name: "Axis",
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    %{source: source, profile: profile} = insert_camera_source!(device_uid)

    {:ok, session} =
      RelaySession.create_session(
        %{
          camera_source_id: source.id,
          stream_profile_id: profile.id,
          agent_id: source.assigned_agent_id,
          gateway_id: source.assigned_gateway_id,
          lease_expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
          requested_by: "camera-relay-live-test"
        },
        actor: AshTestHelpers.system_actor()
      )

    {:ok, _view, html} = live(conn, ~p"/observability/camera-relays")

    assert html =~ "Relay Logs"
    assert html =~ "Agent Logs"
    assert html =~ "Gateway Logs"
    assert html =~ encoded_filter("relay_session_id", session.id)
    assert html =~ encoded_filter("agent_id", source.assigned_agent_id)
    assert html =~ encoded_filter("gateway_id", source.assigned_gateway_id)
  end

  defp encoded_filter(field, value) do
    URI.encode_www_form(~s/#{field}:"#{value}"/)
  end

  defp insert_camera_source!(device_uid) do
    {:ok, source} =
      CameraSource.create_source(
        %{
          device_uid: device_uid,
          vendor: "axis",
          vendor_camera_id: "axis-#{System.unique_integer([:positive])}",
          display_name: "Ops Camera",
          source_url: "rtsp://camera.local/stream",
          assigned_agent_id: "agent-camera-ops-1",
          assigned_gateway_id: "gateway-camera-ops-1"
        },
        actor: AshTestHelpers.system_actor()
      )

    {:ok, profile} =
      CameraStreamProfile.create_profile(
        %{
          camera_source_id: source.id,
          profile_name: "Operations Stream",
          codec_hint: "h264",
          container_hint: "annexb",
          rtsp_transport: "tcp",
          relay_eligible: true
        },
        actor: AshTestHelpers.system_actor()
      )

    %{source: source, profile: profile}
  end
end
