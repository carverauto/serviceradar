defmodule ServiceRadarWebNGWeb.Components.TimeseriesComponentTest do
  @moduledoc """
  Unit tests for the timeseries chart component rendering.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries

  @moduletag :unit

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
end
