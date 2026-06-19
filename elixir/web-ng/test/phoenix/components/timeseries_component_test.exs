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

  test "prefers SRQL metric unit metadata over value field-name inference" do
    points = [
      {~U[2025-01-01 00:00:00Z], 1024.0},
      {~U[2025-01-01 00:05:00Z], 2048.0},
      {~U[2025-01-01 00:10:00Z], 4096.0}
    ]

    html =
      render_component(Timeseries, %{
        id: "ts-row-unit",
        title: "Row Unit",
        panel_assigns: %{chart_mode: :single, rate_mode: :none},
        spec: %{x: "timestamp", y: "value", series: "label", series_units: %{"disk" => :bytes}},
        series_points: [{"disk", points}]
      })

    assert html =~ "4.1 KB"
  end

  test "scales numeric y axis to the data band instead of forcing zero" do
    points = [
      {~U[2025-01-01 00:00:00Z], 80.0},
      {~U[2025-01-01 00:05:00Z], 85.0},
      {~U[2025-01-01 00:10:00Z], 90.0}
    ]

    html =
      render_component(Timeseries, %{
        id: "ts-band",
        title: "Narrow band",
        panel_assigns: %{chart_mode: :single, rate_mode: :none},
        spec: %{x: "timestamp", y: "gauge_value", series: "label"},
        series_points: [{"gauge", points}]
      })

    assert html =~ "79.5"
    assert html =~ "90.5"
  end

  test "supports opt-in log scale for timeseries panels" do
    points = [
      {~U[2025-01-01 00:00:00Z], 1.0},
      {~U[2025-01-01 00:05:00Z], 10.0},
      {~U[2025-01-01 00:10:00Z], 100.0}
    ]

    html =
      render_component(Timeseries, %{
        id: "ts-log",
        title: "Log scale",
        panel_assigns: %{chart_mode: :single, rate_mode: :none, scale_mode: :log},
        spec: %{x: "timestamp", y: "gauge_value", series: "label"},
        series_points: [{"gauge", points}]
      })

    assert html =~ "2.51"
    assert html =~ "39.81"
  end

  test "counter rates drop the synthetic first zero and render resets as gaps" do
    points = [
      {~U[2025-01-01 00:00:00Z], 1_000.0},
      {~U[2025-01-01 00:05:00Z], 7_000.0},
      {~U[2025-01-01 00:10:00Z], 100.0},
      {~U[2025-01-01 00:15:00Z], 3_100.0}
    ]

    html =
      render_component(Timeseries, %{
        id: "ts-counter-gap",
        title: "Traffic",
        panel_assigns: %{chart_mode: :single, rate_mode: :counter},
        series_points: [{"ifInOctets", points}]
      })

    assert html =~ "&quot;v&quot;:null"
    refute html =~ "&quot;v&quot;:0.0"
    assert html =~ ~r/d="M [^"]+ M /
  end
end
