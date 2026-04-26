defmodule ServiceRadarWebNGWeb.Settings.NetflowLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias Ash.Page.Keyset
  alias ServiceRadar.Observability.NetflowLocalCidr
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  require Ash.Query

  setup :register_and_log_in_admin_user

  test "renders netflow settings page", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/settings/netflows")
    assert html =~ "NetFlow Settings"
    assert html =~ "Local CIDRs"
    assert html =~ "Optional Enrichment and Security"
  end

  test "creates a local CIDR entry", %{conn: conn, scope: scope} do
    {:ok, lv, _html} = live(conn, ~p"/settings/netflows/new")

    lv
    |> form("#netflow-cidr-form", %{
      "form" => %{
        "partition" => "default",
        "label" => "RFC1918",
        "cidr" => "10.0.0.0/8",
        "location_label" => "farm01 - Carver, MN",
        "latitude" => "44.7633",
        "longitude" => "-93.6258",
        "enabled" => "true"
      }
    })
    |> render_submit()

    assert_redirect(lv, ~p"/settings/netflows")

    # Validate persistence (navigation is not required for correctness).
    cidrs =
      NetflowLocalCidr
      |> Ash.Query.for_read(:list, %{})
      |> Ash.read!(scope: scope)
      |> unwrap_page()

    assert Enum.any?(cidrs, fn cidr ->
             cidr.cidr == "10.0.0.0/8" and cidr.partition == "default" and
               cidr.location_label == "farm01 - Carver, MN" and cidr.latitude == 44.7633 and
               cidr.longitude == -93.6258
           end)

    {:ok, lv, _html} = live(conn, ~p"/settings/netflows")
    assert has_element?(lv, "td", "10.0.0.0/8")
    assert has_element?(lv, "td", "RFC1918")
    assert has_element?(lv, "td", "farm01 - Carver, MN")
  end

  test "updates optional netflow settings", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings/netflows")

    token = "ipinfo_test_token_123"

    lv
    |> form("#netflow-settings-form", %{
      "settings" => %{
        "ipinfo_enabled" => "true",
        "ipinfo_base_url" => "https://api.ipinfo.io",
        "ipinfo_api_key" => token,
        "threat_intel_enabled" => "true",
        "threat_intel_feed_urls_text" => "https://example.com/feed.txt\n",
        "anomaly_enabled" => "true",
        "anomaly_baseline_window_seconds" => "604800",
        "anomaly_threshold_percent" => "300",
        "port_scan_enabled" => "true",
        "port_scan_window_seconds" => "300",
        "port_scan_unique_ports_threshold" => "50"
      }
    })
    |> render_submit()

    assert render(lv) =~ "Saved settings"
    assert render(lv) =~ "(set)"
    refute render(lv) =~ token
  end

  test "viewer is blocked from netflow settings", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :viewer})
    conn = log_in_user(conn, user)

    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/settings/netflows")
    assert to == ~p"/settings/profile"
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end

  defp unwrap_page(%Keyset{results: results}), do: results
  defp unwrap_page(results) when is_list(results), do: results
  defp unwrap_page({:ok, %Keyset{results: results}}), do: results
  defp unwrap_page({:ok, results}) when is_list(results), do: results
  defp unwrap_page(_), do: []
end
