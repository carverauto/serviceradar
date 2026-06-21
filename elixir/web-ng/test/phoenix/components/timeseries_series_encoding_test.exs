defmodule ServiceRadarWebNGWeb.Components.TimeseriesSeriesEncodingTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries

  @moduletag :unit
  @moduletag :db_free

  test "renders non-color marker and line encodings for individual series charts" do
    points = sample_points()

    html =
      render_component(Timeseries, %{
        id: "ts-series-encoding",
        title: "Encoding",
        panel_assigns: %{chart_mode: :single, rate_mode: :none},
        series_points: [
          {"alpha", points},
          {"beta", points}
        ]
      })

    assert html =~ ~s(data-testid="timeseries-series-marker")
    assert html =~ ~s(data-series-shape="circle")
    assert html =~ ~s(data-series-shape="square")
    assert html =~ ~s(aria-label="Circle series marker")
    assert html =~ ~s(aria-label="Square series marker")
    assert html =~ ~s(stroke-dasharray="5 3")
  end

  test "renders non-color marker and line encodings for combined charts" do
    points = sample_points()

    html =
      render_component(Timeseries, %{
        id: "ts-combined-encoding",
        title: "Encoding",
        panel_assigns: %{
          chart_mode: :combined,
          combine_all_series: true,
          rate_mode: :none
        },
        series_points: [
          {"alpha", points},
          {"beta", points}
        ]
      })

    assert html =~ ~s(id="combined-chart-ts-combined-encoding")
    assert html =~ ~s(data-testid="timeseries-series-marker")
    assert html =~ ~s(data-series-shape="circle")
    assert html =~ ~s(data-series-shape="square")
    assert html =~ ~s(aria-label="Circle series marker")
    assert html =~ ~s(aria-label="Square series marker")
    assert html =~ ~s(stroke-dasharray="5 3")
  end

  defp sample_points do
    [
      {~U[2025-01-01 00:00:00Z], 1.0},
      {~U[2025-01-01 00:05:00Z], 3.0},
      {~U[2025-01-01 00:10:00Z], 2.0}
    ]
  end
end
