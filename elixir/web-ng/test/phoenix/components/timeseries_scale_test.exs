defmodule ServiceRadarWebNGWeb.Components.TimeseriesScaleTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Paths
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.SeriesData

  @moduletag :unit
  @moduletag :db_free

  test "linear charts scale to a padded data band instead of a zero floor" do
    points = [
      {~U[2026-01-01 00:00:00Z], 80.0},
      {~U[2026-01-01 00:05:00Z], 85.0},
      {~U[2026-01-01 00:10:00Z], 90.0}
    ]

    [series] =
      SeriesData.build_series_data(
        [{"cpu", points}],
        %{y: "usage_percent"},
        :none,
        false,
        nil,
        [],
        :linear
      )

    assert series.y_scale == :linear
    assert series.chart_min > 0
    assert series.chart_min < 80.0
    assert series.chart_max > 90.0
    assert series.chart_max <= 100.0
    refute Enum.any?(series.y_ticks, fn {_y, label} -> label == "0.0%" end)

    old_zero_floor_y = Paths.value_to_y(80.0, 0.0, 100.0)
    data_band_y = Paths.value_to_y(80.0, series.chart_min, series.chart_max)

    assert data_band_y > old_zero_floor_y
  end

  test "log scale is opt-in and maps values through a positive log domain" do
    points = [
      {~U[2026-01-01 00:00:00Z], 1.0},
      {~U[2026-01-01 00:05:00Z], 10.0},
      {~U[2026-01-01 00:10:00Z], 100.0}
    ]

    [series] =
      SeriesData.build_series_data(
        [{"latency", points}],
        %{y: "value"},
        :none,
        false,
        nil,
        [],
        :log
      )

    assert series.y_scale == :log
    assert series.chart_min > 0
    assert series.chart_min < 1.0
    assert series.chart_max > 100.0
    assert series.paths.line =~ "M"
    assert length(series.y_ticks) == 6

    low_y = Paths.value_to_y(1.0, series.chart_min, series.chart_max, :log)
    high_y = Paths.value_to_y(100.0, series.chart_min, series.chart_max, :log)

    assert high_y < low_y
  end
end
