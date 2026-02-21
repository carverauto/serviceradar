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

      assert html =~ "Accounts"
      assert html =~ "Add account"
      assert html =~ "id=\"users\""
    end

    test "creates a user", %{conn: conn} do
      admin = AshTestHelpers.admin_user_fixture()

      {:ok, lv, _html} =
        conn
        |> log_in_user(admin)
        |> live(~p"/settings/auth/users")

      {:ok, operator_profile} =
        ServiceRadar.Identity.RoleProfile.get_by_system_name("operator",
          actor: AshTestHelpers.system_actor()
        )

      _ =
        lv
        |> element("button[phx-click='open_add_user_modal']")
        |> render_click()

      result =
        lv
        |> form("#user-create-form", %{
          "user" => %{
            "email" => "lv-user@example.com",
            "display_name" => "LV User",
            "role_profile_id" => operator_profile.id,
            "password" => ""
          }
        })
        |> render_submit()

      assert result =~ "User created"
      assert result =~ "lv-user@example.com"
    end

    test "redirects non-admins", %{conn: conn} do
      user = AshTestHelpers.viewer_user_fixture()

      assert {:error, redirect} =
               conn
               |> log_in_user(user)
               |> live(~p"/settings/auth/users")

      assert {:live_redirect, %{to: path}} = redirect
      # Non-admins land on the main app page (or profile settings depending on route config).
      assert path in [~p"/analytics", ~p"/settings/profile"]
    end
  end
end
