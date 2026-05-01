defmodule ServiceRadarWebNGWeb.DashboardLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  test "renders the operations dashboard inside the authenticated shell", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/dashboard")

    assert html =~ "Unified Operations Dashboard"
    assert has_element?(view, "[data-testid='operations-dashboard']")
    assert has_element?(view, "a[aria-current='page'][href='/dashboard']")
    assert has_element?(view, "#ops-traffic-map[phx-hook='OperationsTrafficMap']")
    assert has_element?(view, "select[name='map_view']", "NetFlow Map")
    assert has_element?(view, "select[name='map_view']", "WiFi Map")
    assert has_element?(view, "a[href='/netflow-map']", "Full Screen")
    assert has_element?(view, "#ops-traffic-map[data-topology-links]")
  end

  test "dashboard WiFi map mode links to the full screen WiFi map", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    assert render_hook(view, "select_map_view", %{"map_view" => "wifi_map"}) =~ "WiFi Map"
    assert has_element?(view, "a[href='/wifi-map']", "Full Screen")
    assert has_element?(view, "a[aria-label='Open full screen WiFi map']")
  end

  test "renders honest empty states for feeds that are not implemented yet", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "[data-testid='traffic-map-empty']")
    assert has_element?(view, "[data-testid='vulnerable-assets-empty']", "No fabricated risk counts are displayed.")
    assert has_element?(view, "[data-testid='siem-alerts-empty']", "No fabricated security alerts are displayed.")
    assert has_element?(view, "[data-testid='fieldsurvey-empty']", "No FieldSurvey heatmap data")
    assert has_element?(view, "[data-testid='camera-operations-empty']", "feed unavailable")
  end
end
