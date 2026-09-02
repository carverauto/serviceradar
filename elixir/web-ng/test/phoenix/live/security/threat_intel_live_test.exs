defmodule ServiceRadarWebNGWeb.Security.ThreatIntelLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.AccountsFixtures

  setup :register_and_log_in_admin_user

  test "admin can open the investigation workspace", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/security/threat-intel")

    assert html =~ "Threat Intel"
    assert html =~ "Current matches"
    assert has_element?(view, "a", "Manage feeds")
    refute html =~ "otx-liveview-secret"
  end

  test "viewer can open investigation but not settings", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :viewer})
    conn = log_in_user(conn, user)

    {:ok, _view, html} = live(conn, ~p"/security/threat-intel")
    assert html =~ "Current matches"

    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/settings/networks/threat-intel")
    assert to == ~p"/settings/profile"
  end
end
