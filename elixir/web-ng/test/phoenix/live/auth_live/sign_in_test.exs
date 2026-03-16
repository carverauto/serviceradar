defmodule ServiceRadarWebNGWeb.AuthLive.SignInTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ServiceRadarWebNG.AccountsFixtures

  test "sign-in page hides registration and magic-link options", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/users/log-in")

    assert has_element?(view, "form[action='/auth/sign-in']")
    refute has_element?(view, "a[href='/users/register']")
    refute has_element?(view, "a", "Create an account")
    refute has_element?(view, "a", "Register")
    refute has_element?(view, "a", "Magic link")
    refute has_element?(view, ".drawer-side")
  end

  test "sign-in page does not render the authenticated sidebar for a logged-in session", %{conn: conn} do
    user = user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/users/log-in")

    refute has_element?(view, ".drawer-side")
  end
end
