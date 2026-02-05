defmodule ServiceRadarWebNGWeb.Settings.AuthUsersLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.AshTestHelpers

  describe "auth users live" do
    test "renders for admin", %{conn: conn} do
      admin = AshTestHelpers.admin_user_fixture()

      {:ok, _lv, html} =
        conn
        |> log_in_user(admin)
        |> live(~p"/settings/auth/users")

      assert html =~ "Users"
      assert html =~ "Add User"
      assert html =~ "user-create-form"
      assert html =~ "id=\"users\""
    end

    test "creates a user", %{conn: conn} do
      admin = AshTestHelpers.admin_user_fixture()

      {:ok, lv, _html} =
        conn
        |> log_in_user(admin)
        |> live(~p"/settings/auth/users")

      result =
        lv
        |> form("#user-create-form", %{
          "user" => %{
            "email" => "lv-user@example.com",
            "display_name" => "LV User",
            "role" => "operator"
          }
        })
        |> render_submit()

      assert result =~ "User created"
      assert result =~ "lv-user@example.com"
    end

    test "redirects non-admins", %{conn: conn} do
      user = AshTestHelpers.user_fixture()

      assert {:error, redirect} =
               conn
               |> log_in_user(user)
               |> live(~p"/settings/auth/users")

      assert {:live_redirect, %{to: path}} = redirect
      assert path == ~p"/settings/profile"
    end
  end
end
