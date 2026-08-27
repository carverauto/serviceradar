defmodule ServiceRadarWebNGWeb.Settings.RbacLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.AshTestHelpers

  test "dashboards section lists authored and package resources without aliased cli keys", %{
    conn: conn
  } do
    admin = AshTestHelpers.admin_user_fixture()

    {:ok, lv, _html} =
      conn
      |> log_in_user(admin)
      |> live(~p"/settings/auth/rbac")

    html =
      lv
      |> element("button[phx-click='select_section'][phx-value-section='dashboards']")
      |> render_click()

    assert html =~ "Authored"
    assert html =~ "Packages"
    refute html =~ "cli.dashboard"
    assert html =~ "publish"
    assert html =~ "share"
    assert html =~ "view all"
  end
end
