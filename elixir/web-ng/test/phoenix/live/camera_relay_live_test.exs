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

    previous_health_source =
      Application.get_env(:serviceradar_web_ng, :camera_relay_health_source)

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

  test "links relay rows to canonical camera devices when sources still use raw MAC ids", %{
    conn: conn
  } do
    canonical_uid = "sr:camera-relay-#{System.unique_integer([:positive])}"
    raw_camera_id = "7845582F3F73"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: canonical_uid,
        mac: raw_camera_id,
        type_id: 7,
        hostname: "front-door-camera",
        vendor_name: "Ubiquiti",
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    %{source: source, profile: profile} =
      insert_camera_source!(raw_camera_id,
        metadata: %{"identity" => %{"mac" => "78:45:58:2F:3F:73"}}
      )

    {:ok, _session} =
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

    {:ok, view, html} = live(conn, ~p"/observability/camera-relays")

    assert has_element?(
             view,
             "a[href='/devices/#{URI.encode_www_form(canonical_uid)}']",
             "View device"
           )

    refute html =~ "/devices/#{raw_camera_id}"
  end

  test "filters expired relay sessions out of the active view and summary", %{conn: conn} do
    %{source: current_source, profile: current_profile} =
      insert_camera_source!("camera-relay-current-#{System.unique_integer([:positive])}")

    %{source: expired_source, profile: expired_profile} =
      insert_camera_source!("camera-relay-expired-#{System.unique_integer([:positive])}")

    {:ok, current_session} =
      RelaySession.create_session(
        %{
          camera_source_id: current_source.id,
          stream_profile_id: current_profile.id,
          agent_id: current_source.assigned_agent_id,
          gateway_id: current_source.assigned_gateway_id,
          lease_expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
          requested_by: "camera-relay-live-test"
        },
        actor: AshTestHelpers.system_actor()
      )

    {:ok, current_session} =
      RelaySession.activate(
        current_session,
        %{
          media_ingest_id: "core-media-current",
          lease_expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
          viewer_count: 1
        },
        actor: AshTestHelpers.system_actor()
      )

    {:ok, expired_session} =
      RelaySession.create_session(
        %{
          camera_source_id: expired_source.id,
          stream_profile_id: expired_profile.id,
          agent_id: expired_source.assigned_agent_id,
          gateway_id: expired_source.assigned_gateway_id,
          lease_expires_at: DateTime.add(DateTime.utc_now(), -300, :second),
          requested_by: "camera-relay-live-test"
        },
        actor: AshTestHelpers.system_actor()
      )

    {:ok, expired_session} =
      RelaySession.activate(
        expired_session,
        %{
          media_ingest_id: "core-media-expired",
          lease_expires_at: DateTime.add(DateTime.utc_now(), -300, :second),
          viewer_count: 1
        },
        actor: AshTestHelpers.system_actor()
      )

    {:ok, _view, html} = live(conn, ~p"/observability/camera-relays")

    assert summary_value(html, "Live Sessions") == "1"
    assert html =~ encoded_filter("relay_session_id", current_session.id)
    refute html =~ encoded_filter("relay_session_id", expired_session.id)
  end

  defp encoded_filter(field, value) do
    URI.encode_www_form(~s/#{field}:"#{value}"/)
  end

  defp summary_value(html, title) do
    regex =
      ~r/#{Regex.escape(title)}<\/div>\s*<div class="mt-2 text-3xl font-semibold tracking-tight text-[^"]+">\s*([^<]+)\s*</s

    case Regex.run(regex, html, capture: :all_but_first) do
      [value] -> String.trim(value)
      _other -> flunk("summary card #{inspect(title)} not found in HTML")
    end
  end

  defp insert_camera_source!(device_uid, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    {:ok, source} =
      CameraSource.create_source(
        %{
          device_uid: device_uid,
          vendor: "axis",
          vendor_camera_id: "axis-#{System.unique_integer([:positive])}",
          display_name: "Ops Camera",
          source_url: "rtsp://camera.local/stream",
          assigned_agent_id: "agent-camera-ops-1",
          assigned_gateway_id: "gateway-camera-ops-1",
          metadata: metadata
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
