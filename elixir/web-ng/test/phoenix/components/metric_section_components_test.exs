defmodule ServiceRadarWebNGWeb.Components.MetricSectionComponentsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries
  alias ServiceRadarWebNGWeb.DeviceLive.MetricSectionComponents

  @moduletag :unit
  @moduletag :db_free

  test "indexes metric section panel component ids when panels share an engine id" do
    points = [
      {~U[2025-01-01 00:00:00Z], 10.0},
      {~U[2025-01-01 00:05:00Z], 20.0}
    ]

    panel = %{
      id: "timeseries",
      title: "Timeseries",
      plugin: Timeseries,
      assigns: %{
        chart_mode: :single,
        rate_mode: :none,
        series_points: [{"usage_percent", points}],
        spec: %{x: "timestamp", y: "usage_percent"}
      }
    }

    html =
      render_component(&MetricSectionComponents.metric_sections_content/1, %{
        device_uid: "sr:test",
        chart_focus: nil,
        sections: [
          %{
            key: "cpu",
            title: "CPU",
            subtitle: "last 24h",
            panels: [panel, panel],
            error: nil,
            header_stats: nil,
            header_value: nil
          }
        ]
      })

    assert html =~ ~s(id="panel-device-sr:test-cpu-timeseries-0")
    assert html =~ ~s(id="panel-device-sr:test-cpu-timeseries-1")
  end
end
