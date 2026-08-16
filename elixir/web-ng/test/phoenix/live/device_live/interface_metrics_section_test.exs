defmodule ServiceRadarWebNGWeb.DeviceLive.InterfaceMetricsSectionTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries
  alias ServiceRadarWebNGWeb.DeviceLive.InterfaceComponents

  @moduletag :db_free

  test "groups favorited interfaces horizontally and shows one full-width panel" do
    html =
      render_component(&InterfaceComponents.interface_metrics_section/1,
        metrics: %{
          has_favorited: true,
          panels: [panel("br0", 29), panel("eth9", 9), panel("wgsts1000", 1000)],
          error: nil,
          favorited_count: 3
        },
        device_uid: "sr:udm",
        selected_key: "29"
      )

    assert html =~ ~s(role="tablist")
    assert html =~ ~s(aria-label="Favorited interfaces")
    assert html =~ ~s(id="favorited-metrics-tab-29")
    assert html =~ ~s(id="favorited-metrics-tab-9")
    assert html =~ ~s(id="favorited-metrics-tab-1000")
    assert html =~ ~s(sr-ui-tab-active)
    assert html =~ "ifIndex 29"
    assert html =~ ~s(data-testid="favorited-interface-metrics-panel")
    assert html =~ ~s(id="favorited-metrics-panel-29")
    refute html =~ "minmax(22rem"
    refute html =~ ~s(id="favorited-metrics-panel-9")
  end

  test "hides the interface tab strip when only one favorite has samples" do
    html =
      render_component(&InterfaceComponents.interface_metrics_section/1,
        metrics: %{
          has_favorited: true,
          panels: [panel("br0", 29)],
          error: nil,
          favorited_count: 1
        },
        device_uid: "sr:udm"
      )

    refute html =~ ~s(role="tablist")
    assert html =~ ~s(data-testid="favorited-interface-metrics-panel")
    assert html =~ "ifIndex 29"
  end

  defp panel(name, if_index) do
    %{
      id: "if-#{if_index}",
      plugin: Timeseries,
      title: "Timeseries",
      assigns: %{
        interface_label: name,
        interface_name: name,
        if_index: if_index,
        chart_mode: :combined,
        series_points: [],
        compact: false
      }
    }
  end
end
