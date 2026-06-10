defmodule ServiceRadarWebNGWeb.SecurityDashboardRoutesTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadarWebNG.Dashboards.FirstPartyPackages

  setup :register_and_log_in_user

  setup do
    actor = SystemActor.system(:first_party_dashboard_route_test)

    assert {:ok, %{packages: seeded}} = FirstPartyPackages.seed_all(actor: actor)
    assert Enum.count(seeded) >= 3

    :ok
  end

  test "security page is reachable from the operations sidebar", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/security")
    html = render(view) <> html

    assert html =~ "Scanner posture and active findings"
    assert html =~ "Bumblebee, Falco, Trivy, endpoint package discovery, and PowerDNS"
    assert has_element?(view, "a[href='/security'][aria-current='page']", "Security")
    assert has_element?(view, "a[href='/dashboards']", "Browse Dashboards")
  end

  test "dashboard hub lists bundled security and endpoint inventory dashboards", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboards")
    html = render_async(view, 5_000)

    assert html =~ "Dashboard Library"
    assert html =~ "Security Findings"
    assert html =~ "Endpoint Inventory"
    assert has_element?(view, "a[href='/dashboards/security-findings']")
    assert has_element?(view, "a[href='/dashboards/endpoint-inventory']")
  end

  test "bundled dashboard routes load the package host", %{conn: conn} do
    for route_slug <- ["security-findings", "endpoint-inventory"] do
      {:ok, view, _html} = live(conn, ~p"/dashboards/#{route_slug}")
      html = render_async(view, 5_000)

      assert html =~ "dashboard-package-host"
      assert has_element?(view, "[phx-hook='DashboardWasmHost'][data-host]")
      refute html =~ "Dashboard package unavailable"
      refute html =~ "Dashboard package failed to load"
    end
  end
end
