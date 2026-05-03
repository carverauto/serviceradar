defmodule ServiceRadarWebNGWeb.DashboardLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Dashboards.DashboardInstance
  alias ServiceRadar.Dashboards.DashboardPackage

  setup :register_and_log_in_user

  test "renders the operations dashboard inside the authenticated shell", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/dashboard")

    assert html =~ "Unified Operations Dashboard"
    assert has_element?(view, "[data-testid='operations-dashboard']")
    assert has_element?(view, "a[aria-current='page'][href='/dashboard']")
    assert has_element?(view, "#ops-traffic-map[phx-hook='OperationsTrafficMap']")
    assert has_element?(view, "select[name='map_view']", "NetFlow Map")
    assert has_element?(view, "a[href='/netflow-map']", "Full Screen")
    assert has_element?(view, "#ops-traffic-map[data-topology-links]")
  end

  test "dashboard falls back to NetFlow for unsupported map modes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    html = render_hook(view, "select_map_view", %{"map_view" => "unsupported"})

    assert html =~ "NetFlow Map"
    assert has_element?(view, "a[href='/netflow-map']", "Full Screen")
  end

  test "dashboard selects the default dashboard package map view", %{conn: conn} do
    route_slug = "dashboard-default-map-#{System.unique_integer([:positive])}"
    create_dashboard_instance!(route_slug)

    {:ok, view, _html} = live(conn, ~p"/dashboard")
    html = render_async(view, 1_000)

    assert html =~ "Default Map Package"
    assert has_element?(view, "option[value='dashboard:#{route_slug}'][selected]")
    assert has_element?(view, "a[href='/dashboards/#{route_slug}']", "Full Screen")
    refute has_element?(view, "#ops-traffic-map[phx-hook='OperationsTrafficMap']")
  end

  test "renders honest empty states for feeds that are not implemented yet", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "[data-testid='traffic-map-empty']")
    assert has_element?(view, "[data-testid='vulnerable-assets-empty']", "No fabricated risk counts are displayed.")
    assert has_element?(view, "[data-testid='siem-alerts-empty']", "No fabricated security alerts are displayed.")
    assert has_element?(view, "[data-testid='fieldsurvey-empty']", "No FieldSurvey heatmap data")
    assert has_element?(view, "[data-testid='camera-operations-empty']", "feed unavailable")
  end

  defp create_dashboard_instance!(route_slug) do
    package =
      DashboardPackage
      |> Ash.Changeset.for_create(:create, package_attrs())
      |> Ash.create!()
      |> Ash.Changeset.for_update(:enable, %{})
      |> Ash.update!()

    DashboardInstance
    |> Ash.Changeset.for_create(:create, %{
      dashboard_package_id: package.id,
      name: "Default Map Package",
      route_slug: route_slug,
      placement: :map,
      enabled: true,
      is_default: true,
      settings: %{},
      metadata: %{}
    })
    |> Ash.create!()
  end

  defp package_attrs do
    manifest = %{
      "id" => "com.test.dashboard.default-map.#{System.unique_integer([:positive])}",
      "name" => "Default Map Package",
      "version" => "0.1.0",
      "renderer" => %{
        "kind" => "browser_module",
        "interface_version" => "dashboard-browser-module-v1",
        "artifact" => "renderer.js",
        "sha256" => String.duplicate("a", 64),
        "trust" => "trusted"
      },
      "data_frames" => [%{"id" => "sites", "query" => "in:wifi_sites", "encoding" => "json_rows"}],
      "capabilities" => ["srql.execute"],
      "settings_schema" => %{}
    }

    %{
      dashboard_id: manifest["id"],
      name: manifest["name"],
      version: manifest["version"],
      manifest: manifest,
      renderer: manifest["renderer"],
      data_frames: manifest["data_frames"],
      capabilities: manifest["capabilities"],
      settings_schema: manifest["settings_schema"],
      wasm_object_key: "dashboards/test/renderer.js",
      content_hash: String.duplicate("a", 64),
      verification_status: "verified"
    }
  end
end
