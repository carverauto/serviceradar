defmodule ServiceRadarWebNGWeb.Flows.AttributedLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.AshTestHelpers

  setup %{conn: conn} do
    user = AshTestHelpers.admin_user_fixture()

    %{conn: log_in_user(conn, user)}
  end

  test "renders attributed flow fixture rows with process fields", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/observability/flows/attributed")

    assert html =~ "Attributed Flows"
    assert html =~ "10.42.10.12:53844"
    assert html =~ "198.51.100.20:443"
    assert html =~ "1234"
    assert html =~ "nginx"
    assert html =~ "/usr/sbin/nginx args:sha256:31f0e4c8"
  end

  test "renders unmatched rows with attribution placeholders", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/observability/flows/attributed")

    assert html =~ "203.0.113.44:62001"
    assert html =~ "10.42.10.12:22"
    assert html =~ "-"
  end
end
