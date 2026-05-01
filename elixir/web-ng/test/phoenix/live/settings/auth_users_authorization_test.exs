defmodule ServiceRadarWebNGWeb.Settings.AuthUsersAuthorizationTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  import ServiceRadarWebNG.AshTestHelpers,
    only: [admin_user_fixture: 0, viewer_user_fixture: 0]

  describe "/settings/auth/* authorization" do
    test "redirects viewers without settings.auth.manage", %{conn: conn} do
      user = viewer_user_fixture()
      conn = log_in_user(conn, user)

      assert {:error, {:live_redirect, %{to: "/dashboard"} = info}} =
               live(conn, ~p"/settings/auth/users")

      assert is_map(info.flash)
    end

    test "allows admins with settings.auth.manage", %{conn: conn} do
      user = admin_user_fixture()
      conn = log_in_user(conn, user)

      {:ok, _lv, html} = live(conn, ~p"/settings/auth/users")
      assert html =~ "Accounts"
    end
  end
end
