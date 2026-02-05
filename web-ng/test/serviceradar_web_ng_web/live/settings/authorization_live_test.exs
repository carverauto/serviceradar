defmodule ServiceRadarWebNGWeb.Settings.AuthorizationLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.AshTestHelpers

  describe "authorization settings live" do
    test "renders for admin", %{conn: conn} do
      admin = AshTestHelpers.admin_user_fixture()

      {:ok, _lv, html} =
        conn
        |> log_in_user(admin)
        |> live(~p"/settings/auth/authorization")

      assert html =~ "Authorization"
      assert html =~ "authorization-form"
    end

    test "updates settings", %{conn: conn} do
      admin = AshTestHelpers.admin_user_fixture()

      {:ok, lv, _html} =
        conn
        |> log_in_user(admin)
        |> live(~p"/settings/auth/authorization")

      params = %{
        "settings" => %{
          "default_role" => "operator",
          "role_mappings" =>
            "[\n  {\"source\": \"groups\", \"value\": \"NetOps\", \"role\": \"operator\"}\n]"
        }
      }

      result =
        lv
        |> form("#authorization-form", params)
        |> render_submit()

      assert result =~ "Authorization settings updated"
    end

    test "shows json error", %{conn: conn} do
      admin = AshTestHelpers.admin_user_fixture()

      {:ok, lv, _html} =
        conn
        |> log_in_user(admin)
        |> live(~p"/settings/auth/authorization")

      result =
        lv
        |> form("#authorization-form", %{
          "settings" => %{
            "default_role" => "viewer",
            "role_mappings" => "{invalid json}"
          }
        })
        |> render_submit()

      assert result =~ "Role mappings must be valid JSON"
    end

    test "redirects non-admins", %{conn: conn} do
      user = AshTestHelpers.user_fixture()

      assert {:error, redirect} =
               conn
               |> log_in_user(user)
               |> live(~p"/settings/auth/authorization")

      assert {:live_redirect, %{to: path}} = redirect
      assert path == ~p"/settings/profile"
    end
  end
end
