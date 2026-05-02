defmodule ServiceRadarWebNGWeb.CameraAnalysisWorkerLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import ServiceRadarWebNG.AshTestHelpers,
    only: [admin_user_fixture: 0, viewer_user_fixture: 0]

  alias ServiceRadarWebNG.TestSupport.CameraAnalysisWorkersStub

  setup %{conn: conn} do
    previous_module = Application.get_env(:serviceradar_web_ng, :camera_analysis_workers)

    previous_test_pid =
      Application.get_env(:serviceradar_web_ng, :camera_analysis_workers_test_pid)

    Application.put_env(
      :serviceradar_web_ng,
      :camera_analysis_workers,
      CameraAnalysisWorkersStub
    )

    Application.put_env(:serviceradar_web_ng, :camera_analysis_workers_test_pid, self())

    on_exit(fn ->
      restore_env(:camera_analysis_workers, previous_module)
      restore_env(:camera_analysis_workers_test_pid, previous_test_pid)
    end)

    user = admin_user_fixture()

    %{conn: log_in_user(conn, user)}
  end

  test "renders the camera analysis worker operations page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/observability/camera-relays/workers")

    assert html =~ "Observability"
    assert html =~ "Camera Relays"
    assert html =~ "Analysis Workers"
    assert html =~ "Camera Analysis Workers"
    assert html =~ "Alpha Detector"
    assert html =~ "Beta Detector"
    assert html =~ "worker-alpha"
    assert html =~ "worker-beta"
    assert html =~ "Registered"
    assert html =~ "Healthy"
    assert html =~ "Unhealthy"
    assert html =~ "Flapping"
    assert html =~ "Alerts"
    assert html =~ "Active Assignments"
    assert html =~ "http://alpha.local/readyz"
    assert html =~ "active: 2"
    assert html =~ "relay-alpha-1/branch-alpha-1"
    assert html =~ "relay-alpha-2/branch-alpha-2"
    assert html =~ "idle"
    assert html =~ "timeout: 1500 ms"
    assert html =~ "interval: 10000 ms"
    assert html =~ "flapping"
    assert html =~ "4 transitions / 5 probes"
    assert html =~ "alert: flapping"
    assert html =~ "notification policy: standard_alert (camera_analysis_worker_routed_alert)"
    assert html =~ "notification policy: inactive"
    assert html =~ "notification audit: 2 sent, last 2027-01-15 08:02:00 UTC, alert pending"
    assert html =~ "notification audit: none"
    assert html =~ "status_transitions_threshold"
    assert html =~ "observability key: camera_analysis_worker:worker-beta:flapping"
    assert html =~ "http_status_503"
    assert html =~ "2026-03-24T15:00:00Z"

    assert_receive {:camera_analysis_workers_list, opts}
    assert opts[:scope]
  end

  test "toggles worker enabled state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/observability/camera-relays/workers")
    worker_id = "00000000-0000-0000-0000-000000000101"

    html =
      view
      |> element("button[phx-value-id='#{worker_id}']")
      |> render_click()

    assert html =~ "Worker disabled"

    assert_receive {:camera_analysis_workers_set_enabled, ^worker_id, false, opts}
    assert opts[:scope]
  end

  test "legacy worker route redirects to the camera relays subsection", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/observability/camera-relays/workers"}}} =
             live(conn, ~p"/observability/camera-analysis-workers")
  end

  test "redirects viewers without settings.edge.manage", %{conn: conn} do
    viewer = viewer_user_fixture()
    conn = log_in_user(build_conn(), viewer)

    assert {:error, {:live_redirect, %{to: "/dashboard"} = info}} =
             live(conn, ~p"/observability/camera-relays/workers")

    assert is_map(info.flash)
  end
end
