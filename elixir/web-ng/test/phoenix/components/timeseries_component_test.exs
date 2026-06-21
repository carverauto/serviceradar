defmodule ServiceRadarWebNGWeb.Components.TimeseriesComponentTest do
  @moduledoc """
  Unit tests for the timeseries chart component rendering.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries

  @moduletag :unit
  @moduletag :db_free

  test "renders gridlines and axis labels" do
    points = [
      {~U[2025-01-01 00:00:00Z], 0.0},
      {~U[2025-01-01 00:05:00Z], 1024.0},
      {~U[2025-01-01 00:10:00Z], 2048.0},
      {~U[2025-01-01 00:15:00Z], 4096.0}
    ]

    series_points = [{"ifInOctets", points}]

    html =
      render_component(Timeseries, %{
        id: "ts-axes",
        title: "Traffic",
        panel_assigns: %{chart_mode: :single, rate_mode: :none},
        series_points: series_points
      })

    assert html =~ "stroke-dasharray=\"3 4\""
    assert html =~ "12:00 AM"
  end

  test "renders timestamp annotations as SVG markers" do
    points = [
      {~U[2025-01-01 00:00:00Z], 10.0},
      {~U[2025-01-01 00:10:00Z], 20.0},
      {~U[2025-01-01 00:20:00Z], 30.0}
    ]

    html =
      render_component(Timeseries, %{
        id: "ts-annotations",
        title: "Annotated",
        panel_assigns: %{
          chart_mode: :single,
          rate_mode: :none,
          annotations: [
            %{
              dt: ~U[2025-01-01 00:05:00Z],
              label: "Anomaly finding",
              severity: "critical"
            }
          ]
        },
        series_points: [{"cpu", points}]
      })

    assert html =~ "data-testid=\"timeseries-annotations\""
    assert html =~ "data-testid=\"timeseries-annotation\""
    assert html =~ "data-annotation-label=\"Anomaly finding\""
    assert html =~ "data-annotation-severity=\"critical\""
    assert html =~ "x1=\"204.0\""
    assert html =~ "#EF4444"
  end

  test "formats percent axis labels for usage percent metrics" do
    points = [
      {~U[2025-01-01 00:00:00Z], 10.0},
      {~U[2025-01-01 00:05:00Z], 55.5},
      {~U[2025-01-01 00:10:00Z], 90.0}
    ]

    series_points = [{"cpu", points}]

    html =
      render_component(Timeseries, %{
        id: "ts-percent",
        title: "CPU",
        panel_assigns: %{chart_mode: :single, rate_mode: :none},
        spec: %{x: "timestamp", y: "usage_percent", series: "label"},
        series_points: series_points
      })

    assert html =~ "%"
  end

  test "prefers SRQL metric unit metadata over field-name inference" do
    points = [
      {~U[2025-01-01 00:00:00Z], 1024.0},
      {~U[2025-01-01 00:05:00Z], 4096.0}
    ]

    html =
      render_component(Timeseries, %{
        id: "ts-unit-metadata",
        title: "Disk",
        panel_assigns: %{chart_mode: :single, rate_mode: :none},
        spec: %{x: "timestamp", y: "value", series: "label", series_units: %{"disk" => :bytes}},
        series_points: [{"disk", points}]
      })

    assert html =~ ~s(data-unit="bytes")
    assert html =~ "4.1 KB"
  end
end
