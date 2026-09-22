defmodule ServiceRadarWebNGWeb.Components.TimeseriesPointsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Paths
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

  test "a 90 day window labels months across the window, not the clock time of the samples" do
    now = ~U[2026-09-21 12:00:00Z]
    start = DateTime.add(now, -90, :day)

    points = [
      {~U[2026-09-16 19:00:00Z], 7.0},
      {~U[2026-09-21 07:00:00Z], 7.7}
    ]

    opts = %{
      time_first: DateTime.to_unix(start, :millisecond),
      time_last: DateTime.to_unix(now, :millisecond)
    }

    ticks = Points.x_ticks(points, false, opts)
    months = Enum.map(ticks, fn {_x, iso} -> String.slice(iso, 0, 7) end)

    assert "2026-07" in months
    assert "2026-08" in months
    assert "2026-09" in months

    late = Paths.datetime_to_x(~U[2026-09-21 07:00:00Z], points, opts)
    [{left, _} | _] = ticks
    assert late > left
  end
end
