defmodule ServiceRadarWebNGWeb.Components.TimeseriesPointsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Points

  @moduletag :unit
  @moduletag :db_free

  test "chart_points preserves measured bytes per second samples without interpolation or smoothing" do
    points = [
      {~U[2025-01-01 00:00:00Z], 0.0},
      {~U[2025-01-01 00:01:00Z], 100.0},
      {~U[2025-01-01 00:02:00Z], 0.0}
    ]

    assert Points.chart_points(points, :bytes_per_sec, false, 800) == points
    assert Points.chart_points(points, :bytes_per_sec, true, 800) == points
  end

  test "time presentation data remains canonical until the last render boundary" do
    points = [
      {~U[2026-08-30 18:00:00Z], 1.0},
      {~U[2026-08-30 18:05:00Z], 2.0}
    ]

    assert Enum.map(Points.x_ticks(points, false), &elem(&1, 1)) == [
             "2026-08-30T18:00:00Z",
             "2026-08-30T18:05:00Z"
           ]

    assert Points.series_first_dt(points) == ~U[2026-08-30 18:00:00Z]
    assert Points.series_last_dt(points) == ~U[2026-08-30 18:05:00Z]
  end
end
