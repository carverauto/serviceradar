defmodule ServiceRadarWebNGWeb.Settings.AuthenticationLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.AshTestHelpers

  test "treats password-only mode as SSO disabled and repairs a contradictory saved flag", %{conn: conn} do
    Repo.query!("""
    UPDATE platform.auth_settings
       SET mode = 'password_only',
           is_enabled = true,
           updated_at = now()
    """)

    admin = AshTestHelpers.admin_user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(admin)
      |> live(~p"/settings/authentication")

    assert has_element?(
             view,
             "#authentication-status[data-auth-mode='password_only'][data-sso-enabled='false']"
           )

    assert has_element?(view, "#authentication-settings-form input[name='settings[is_enabled]'][disabled]")

    view
    |> form("#authentication-settings-form", %{
      "settings" => %{"is_enabled" => "true", "mode" => "password_only"}
    })
    |> render_submit()

    assert %{rows: [[false]]} = Repo.query!("SELECT is_enabled FROM platform.auth_settings LIMIT 1")
  end
end
