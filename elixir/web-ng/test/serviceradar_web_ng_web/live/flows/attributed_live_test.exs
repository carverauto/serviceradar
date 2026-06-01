defmodule ServiceRadarWebNGWeb.Flows.AttributedLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.AshTestHelpers

  setup %{conn: conn} do
    user = AshTestHelpers.admin_user_fixture()

    %{conn: log_in_user(conn, user)}
  end

  test "renders attributed flow table without fixture rows", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/observability/flows/attributed")

    assert html =~ "Attributed Flows"
    assert html =~ "No attributed flow records found"
    refute html =~ "10.42.10.12:53844"
    refute html =~ "198.51.100.20:443"
    refute html =~ "/usr/sbin/nginx args:sha256:31f0e4c8"
    refute html =~ "cri-o://web-frontend"
  end
end
