defmodule ServiceRadarWebNGWeb.Flows.AttributedLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.AshTestHelpers

  setup %{conn: conn} do
    user = AshTestHelpers.admin_user_fixture()

    %{conn: log_in_user(conn, user)}
  end

  test "defaults to attributed rows and opens process details", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/observability/flows/attributed")

    assert html =~ "Attributed Flows"
    assert html =~ "Attributed Flow Records"
    assert html =~ "10.42.10.12:53844"
    assert html =~ "198.51.100.20:443"
    assert html =~ "1234"
    assert html =~ "nginx"
    refute html =~ "203.0.113.44:62001"

    html = view |> element("#attributed-flows button", "nginx") |> render_click()

    assert html =~ "/usr/sbin/nginx args:sha256:31f0e4c8"
  end

  test "renders unmatched rows through the explicit filter", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/observability/flows/attributed?#{%{filter: "unmatched"}}")

    assert html =~ "Unmatched Flow Records"
    assert html =~ "203.0.113.44:62001"
    assert html =~ "10.42.10.12:22"
    assert html =~ "No process match"
  end
end
