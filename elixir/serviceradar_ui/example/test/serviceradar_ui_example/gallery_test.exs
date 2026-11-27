defmodule ServiceRadarUIExample.GalleryTest do
  use ServiceRadarUIExample.ConnCase, async: true

  @static ~w(
    /app.js
    /serviceradar_ui/theme_init.js
    /serviceradar_ui/serviceradar_ui.js
    /serviceradar_ui/serviceradar_ui.js.map
    /serviceradar_ui/world-110m.json
    /serviceradar_ui/css/tokens.css
    /serviceradar_ui/css/components.css
    /vendor/phoenix.mjs
    /vendor/phoenix_live_view.esm.js
  )

  test "gallery uses every hook under the strict CSP", %{conn: conn} do
    conn = get(conn, "/")

    assert [ServiceRadarUIExample.CSP.policy()] ==
             get_resp_header(conn, "content-security-policy")

    html = html_response(conn, 200)

    refute html =~ ~r/\sstyle\s*=/i
    refute html =~ ~r/<script(?![^>]*\bsrc\s*=)[^>]*>/i
    refute html =~ ~r/\son[a-z]+\s*=/i
    refute html =~ "javascript:"

    assert html =~ ~s(src="/serviceradar_ui/theme_init.js")
    assert html =~ ~s(data-sr-theme-key="sr:theme")
    assert html =~ ~s(src="/app.js")

    for hook <- ~w(SrSparkline SrTimeseries SrWorldMap SrDialog) do
      assert html =~ ~s(phx-hook="#{hook}")
    end

    for class <-
          ~w(sr-ui-btn sr-ui-badge sr-ui-panel sr-ui-surface sr-ui-alert sr-ui-flash sr-ui-modal sr-ui-tabs sr-ui-dropdown sr-ui-table sr-ui-pagination sr-ui-spinner sr-ui-field sr-ui-skip-link sr-ui-topbar sr-ui-footer sr-ui-theme-toggle sr-chart-sparkline sr-chart-area sr-chart-bar sr-chart-donut sr-chart-gauge sr-map) do
      assert html =~ class
    end
  end

  for path <- @static do
    test "serves #{path}", %{conn: conn} do
      conn = get(conn, unquote(path))
      body = response(conn, 200)
      assert byte_size(body) > 0
    end
  end

  test "the hook bundle has no tile server and the topology is separate", %{conn: conn} do
    bundle = response(get(conn, "/serviceradar_ui/serviceradar_ui.js"), 200)
    topology = response(get(conn, "/serviceradar_ui/world-110m.json"), 200)

    assert bundle =~ "SrWorldMap"
    refute bundle =~ "openstreetmap"
    refute bundle =~ "mapbox"
    refute bundle =~ "Fiji"

    assert topology =~ "Topology"
    assert topology =~ "Fiji"
  end
end
