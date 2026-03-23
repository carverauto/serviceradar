defmodule ServiceRadarWebNGWeb.CameraRelayLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.AshTestHelpers

  setup %{conn: conn} do
    user = AshTestHelpers.admin_user_fixture()

    %{conn: log_in_user(conn, user)}
  end

  test "renders camera relay operations page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/observability/camera-relays")

    assert html =~ "Camera Relay Operations"
    assert html =~ "Active Relay Sessions"
    assert html =~ "Recent Terminal Sessions"
    assert html =~ "Viewer Idle"
    assert html =~ "Failures"
  end
end
