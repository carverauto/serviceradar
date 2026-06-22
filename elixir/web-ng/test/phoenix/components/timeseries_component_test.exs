defmodule ServiceRadarWebNGWeb.Components.TimeseriesComponentTest do
  @moduledoc """
  Unit tests for the timeseries chart component rendering.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Points

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

  test "focuses a finding on its matching series and time window" do
    points =
      for minute <- 0..20 do
        {DateTime.add(~U[2025-01-01 00:00:00Z], minute, :minute), minute * 1.0}
      end

    html =
      render_component(Timeseries, %{
        id: "ts-focused-finding",
        title: "Focused finding",
        panel_assigns: %{
          chart_mode: :single,
          rate_mode: :none,
          chart_focus: %{
            timestamp: ~U[2025-01-01 00:10:00Z],
            label: "CPU saturation",
            severity: "critical",
            series: "cpu1",
            window_seconds: 60
          }
        },
        series_points: [
          {"cpu0", points},
          {"cpu1", points}
        ]
      })

    assert html =~ "CPU saturation"
    assert html =~ "data-annotation-label=\"CPU saturation\""
    assert html =~ "x1=\"400.0\""
    assert html =~ "cpu1"
    refute html =~ "cpu0"
    assert html =~ "12:09 AM"
    assert html =~ "12:11 AM"
    refute html =~ "12:00 AM"
    refute html =~ "12:20 AM"
  end

  test "renders threshold reference lines and includes them in the y domain" do
    points = [
      {~U[2025-01-01 00:00:00Z], 10.0},
      {~U[2025-01-01 00:10:00Z], 20.0},
      {~U[2025-01-01 00:20:00Z], 30.0}
    ]

    html =
      render_component(Timeseries, %{
        id: "ts-threshold",
        title: "Threshold",
        panel_assigns: %{
          chart_mode: :single,
          rate_mode: :none,
          reference_lines: [
            %{
              value: 80.0,
              label: "Warning threshold",
              severity: "warning",
              series: "cpu"
            }
          ]
        },
        spec: %{x: "timestamp", y: "usage_percent", series: "label"},
        series_points: [{"cpu", points}]
      })

    assert html =~ "data-testid=\"timeseries-reference-lines\""
    assert html =~ "data-testid=\"timeseries-reference-line\""
    assert html =~ "data-reference-label=\"Warning threshold\""
    assert html =~ "data-reference-severity=\"warning\""
    assert html =~ "data-reference-series=\"cpu\""
    assert html =~ "Warning threshold - 80.0%"
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

  test "downsampling preserves bucket minima and maxima" do
    start_dt = ~U[2025-01-01 00:00:00Z]
    spike_dt = DateTime.add(start_dt, 457, :second)
    dip_dt = DateTime.add(start_dt, 612, :second)

    points =
      for idx <- 0..999 do
        dt = DateTime.add(start_dt, idx, :second)

        value =
          cond do
            dt == spike_dt -> 999.0
            dt == dip_dt -> -50.0
            true -> 10.0
          end

        {dt, value}
      end

    limited = Points.limit_points(points, 80)

    assert length(limited) <= 80
    assert List.first(limited) == List.first(points)
    assert List.last(limited) == List.last(points)
    assert {spike_dt, 999.0} in limited
    assert {dip_dt, -50.0} in limited

    assert limited ==
             Enum.sort_by(limited, fn {dt, _value} -> DateTime.to_unix(dt, :microsecond) end)
  end
end
