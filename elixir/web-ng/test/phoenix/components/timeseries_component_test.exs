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

  test "build carries metric unit from SRQL rows into the panel spec" do
    response = %{
      "viz" => %{
        "suggestions" => [
          %{"kind" => "timeseries", "x" => "timestamp", "y" => "value", "series" => "metric"}
        ]
      },
      "results" => [
        %{
          "timestamp" => "2025-01-01T00:00:00Z",
          "metric" => "disk.free",
          "value" => 2048.0,
          "unit" => "bytes"
        }
      ]
    }

    assert {:ok, %{spec: %{unit: "bytes"}, series_points: [{"disk.free", [_point]}]}} =
             Timeseries.build(response)
  end

  test "explicit metric unit is preferred over generic field names" do
    points = [
      {~U[2025-01-01 00:00:00Z], 1024.0},
      {~U[2025-01-01 00:05:00Z], 2048.0}
    ]

    html =
      render_component(Timeseries, %{
        id: "ts-explicit-unit",
        title: "Disk",
        panel_assigns: %{chart_mode: :single, rate_mode: :none},
        spec: %{x: "timestamp", y: "value", series: "label", unit: "bytes"},
        series_points: [{"disk", points}]
      })

    assert html =~ "KB"
    refute html =~ "2048.0"
  end

  test "single-series percent charts use a padded data scale by default" do
    points = [
      {~U[2025-01-01 00:00:00Z], 54.0},
      {~U[2025-01-01 00:05:00Z], 55.0},
      {~U[2025-01-01 00:10:00Z], 56.0}
    ]

    html =
      render_component(Timeseries, %{
        id: "ts-percent-band",
        title: "CPU",
        panel_assigns: %{chart_mode: :single, rate_mode: :none},
        spec: %{x: "timestamp", y: "usage_percent", series: "label"},
        series_points: [{"cpu", points}]
      })

    assert html =~ "53.8%"
    assert html =~ "56.2%"
    refute html =~ "0.0%"
  end

  test "single-series percent charts can opt back into a zero baseline" do
    points = [
      {~U[2025-01-01 00:00:00Z], 54.0},
      {~U[2025-01-01 00:05:00Z], 55.0},
      {~U[2025-01-01 00:10:00Z], 56.0}
    ]

    html =
      render_component(Timeseries, %{
        id: "ts-percent-zero",
        title: "CPU",
        panel_assigns: %{chart_mode: :single, rate_mode: :none, y_scale: :zero},
        spec: %{x: "timestamp", y: "usage_percent", series: "label"},
        series_points: [{"cpu", points}]
      })

    assert html =~ "0.0%"
    assert html =~ "100.0%"
  end

  test "downsampling preserves narrow spikes" do
    base = ~U[2025-01-01 00:00:00Z]

    points =
      Enum.map(0..999, fn idx ->
        value = if idx == 401, do: 999.0, else: 1.0
        {DateTime.add(base, idx * 60, :second), value}
      end)

    html =
      render_component(Timeseries, %{
        id: "ts-spike-envelope",
        title: "Spike",
        panel_assigns: %{chart_mode: :single, rate_mode: :none},
        series_points: [{"series", points}]
      })

    assert html =~ "peak:"
    assert html =~ "999.0"
  end

  test "byte-rate charts do not smooth measured counter rates" do
    points = [
      {~U[2025-01-01 00:00:00Z], 0.0},
      {~U[2025-01-01 00:01:00Z], 60_000.0},
      {~U[2025-01-01 00:02:00Z], 60_000.0},
      {~U[2025-01-01 00:03:00Z], 120_000.0}
    ]

    html =
      render_component(Timeseries, %{
        id: "ts-rate-unsmoothed",
        title: "Traffic",
        panel_assigns: %{chart_mode: :single, rate_mode: :counter},
        series_points: [{"ifInOctets", points}]
      })

    assert html =~ "peak:"
    assert html =~ "1.0 KB/s"
  end
end
