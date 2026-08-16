defmodule ServiceRadarWebNGWeb.DashboardLive.VulnerableAssetsPanelTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.DashboardLive.Data.VulnerableAssets
  alias ServiceRadarWebNGWeb.DashboardLive.Index.VulnerableAssetsPanel

  @moduletag :db_free

  test "present_row prefers hostname and derives a missing risk level" do
    asset =
      VulnerableAssets.present_row({"sr:udm", "edge-gw-01", "UDM", "192.168.1.1", "Network Device", 92, nil, true})

    assert asset.name == "edge-gw-01"
    assert asset.type == "Network Device"
    assert asset.risk_score == 92
    assert asset.risk_level == "Critical"
    assert asset.href == "/devices/sr:udm"
  end

  test "lists scored assets with inventory links" do
    html =
      render_component(&VulnerableAssetsPanel.render/1,
        dashboard: %{
          vulnerable_assets: [
            %{
              uid: "sr:udm",
              name: "edge-gw-01",
              type: "Network Device",
              risk_score: 92,
              risk_level: "Critical",
              available?: true,
              href: "/devices/sr:udm"
            },
            %{
              uid: "alma-test01",
              name: "alma-test01",
              type: "Server",
              risk_score: 71,
              risk_level: "High",
              available?: true,
              href: "/devices/alma-test01"
            }
          ]
        }
      )

    assert html =~ "Top Vulnerable Assets"
    assert html =~ "edge-gw-01"
    assert html =~ "92"
    assert html =~ "Critical"
    assert html =~ ~s(href="/devices/sr:udm")
    assert html =~ ~s(href="/devices")
    assert html =~ "View All Assets"
    refute html =~ "No scored assets yet"
  end

  test "empty state explains that scores come from risk assessment" do
    html =
      render_component(&VulnerableAssetsPanel.render/1,
        dashboard: %{vulnerable_assets: []}
      )

    assert html =~ "No scored assets yet"
    assert html =~ "endpoint inventory"
    assert html =~ "ScaLibr"
    assert html =~ "View All Assets"
  end
end
