defmodule ServiceRadarWebNGWeb.CameraAnalysisWorkerLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import ServiceRadarWebNG.AshTestHelpers,
    only: [admin_user_fixture: 0, viewer_user_fixture: 0]

  alias ServiceRadarWebNG.TestSupport.CameraAnalysisWorkersStub

  setup %{conn: conn} do
    previous_module = Application.get_env(:serviceradar_web_ng, :camera_analysis_workers)
    previous_test_pid = Application.get_env(:serviceradar_web_ng, :camera_analysis_workers_test_pid)

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
    {:ok, _view, html} = live(conn, ~p"/observability/camera-analysis-workers")

    assert html =~ "Camera Analysis Workers"
    assert html =~ "Alpha Detector"
    assert html =~ "Beta Detector"
    assert html =~ "worker-alpha"
    assert html =~ "worker-beta"
    assert html =~ "Registered"
    assert html =~ "Healthy"
    assert html =~ "Unhealthy"

    assert_receive {:camera_analysis_workers_list, opts}
    assert opts[:scope]
  end

  test "toggles worker enabled state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/observability/camera-analysis-workers")
    worker_id = "00000000-0000-0000-0000-000000000101"

    html =
      view
      |> element("button[phx-value-id='#{worker_id}']")
      |> render_click()

    assert html =~ "Worker disabled"

    assert_receive {:camera_analysis_workers_set_enabled, ^worker_id, false, opts}
    assert opts[:scope]
  end

  test "redirects viewers without settings.edge.manage", %{conn: conn} do
    viewer = viewer_user_fixture()
    conn = log_in_user(build_conn(), viewer)

    assert {:error, {:live_redirect, %{to: "/analytics"} = info}} =
             live(conn, ~p"/observability/camera-analysis-workers")

    assert is_map(info.flash)
  end
end
