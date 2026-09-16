defmodule ServiceRadarWebNGWeb.Components.TimeseriesPointsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Paths
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Points

  test "sparse samples retain their positions in a requested 90-day window" do
    start_dt = ~U[2025-01-01 00:00:00Z]
    end_dt = ~U[2025-04-01 00:00:00Z]
    points = [{~U[2025-03-31 00:00:00Z], 10.0}, {~U[2025-03-31 12:00:00Z], 20.0}]
    opts = %{time_window: {start_dt, end_dt}}
    ticks = Points.x_ticks(points, false, opts)

    assert length(ticks) == 5
    assert elem(hd(ticks), 1) == "2025-01-01T00:00:00.000Z"
    assert elem(List.last(ticks), 1) == "2025-04-01T00:00:00.000Z"
    assert Paths.datetime_to_x(elem(hd(points), 0), points, opts) > 750
    assert Paths.datetime_to_x(elem(List.last(points), 0), points, opts) < 768
    assert Points.series_first_dt(points) == ~U[2025-03-31 00:00:00Z]
    assert Points.series_last_dt(points) == ~U[2025-03-31 12:00:00Z]
    assert Paths.datetime_to_x(DateTime.add(start_dt, -60), points, opts) == 72.0
  end

  test "invalid requested bounds retain the sample-driven chart" do
    points = [{~U[2025-01-01 00:00:00Z], 1.0}, {~U[2025-01-01 00:05:00Z], 2.0}]

    assert Points.x_ticks(points, false, time_window: {elem(hd(points), 0), elem(hd(points), 0)}) ==
             Points.x_ticks(points, false)
  end

  test "first and last samples describe all displayed series" do
    series = [
      {"first", [{~U[2025-03-31 12:00:00Z], 1.0}]},
      {"second", [{~U[2025-03-31 00:00:00Z], 2.0}, {~U[2025-03-31 18:00:00Z], 3.0}]}
    ]

    assert Points.first_dt(series) == ~U[2025-03-31 00:00:00Z]
    assert Points.last_dt(series) == ~U[2025-03-31 18:00:00Z]
    assert Points.first_dt([]) == nil
    assert Points.last_dt([]) == nil
  end

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
