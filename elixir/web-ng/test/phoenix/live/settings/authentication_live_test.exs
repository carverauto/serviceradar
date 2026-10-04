defmodule ServiceRadarWebNGWeb.Settings.AuthenticationLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.AshTestHelpers

  @moduletag :web_ng_shared_fixture_db

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

    # The checkbox is disabled, so a browser never submits it. A stale or
    # hand-crafted client still can; pass the contradictory flag outside the
    # form's validated fields the way such a client would.
    view
    |> form("#authentication-settings-form", %{"settings" => %{"mode" => "password_only"}})
    |> render_submit(%{"settings" => %{"is_enabled" => "true"}})

    assert %{rows: [[false]]} = Repo.query!("SELECT is_enabled FROM platform.auth_settings LIMIT 1")
  end
end
