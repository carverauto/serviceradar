defmodule ServiceRadarWebNGWeb.AuthLive.SignInTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "sign-in page hides registration and magic-link options", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/users/log-in")

    assert has_element?(view, "form[action='/auth/sign-in']")
    refute has_element?(view, "a[href='/users/register']")
    refute has_element?(view, "a", "Create an account")
    refute has_element?(view, "a", "Register")
    refute has_element?(view, "a", "Magic link")
  end
end
