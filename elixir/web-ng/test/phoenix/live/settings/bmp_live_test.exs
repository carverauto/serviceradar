defmodule ServiceRadarWebNGWeb.Settings.BmpLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  setup :register_and_log_in_admin_user

  test "renders bmp settings page", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/settings/networks/bmp")

    assert html =~ "BMP Settings"
    assert html =~ "Routing retention (days)"
    assert html =~ "OCSF promotion min severity"
  end

  test "updates bmp settings", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/bmp")

    lv
    |> form("#bmp-settings-form", %{
      "settings" => %{
        "bmp_routing_retention_days" => "5",
        "bmp_ocsf_min_severity" => "3",
        "god_view_causal_overlay_window_seconds" => "240",
        "god_view_causal_overlay_max_events" => "700",
        "god_view_routing_causal_severity_threshold" => "2"
      }
    })
    |> render_submit()

    assert render(lv) =~ "Saved BMP settings"
  end

  test "viewer is blocked from bmp settings", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :viewer})
    conn = log_in_user(conn, user)

    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/settings/networks/bmp")
    assert to == ~p"/settings/profile"
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end
end
