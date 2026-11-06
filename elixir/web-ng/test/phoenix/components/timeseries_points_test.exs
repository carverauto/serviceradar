defmodule ServiceRadarWebNGWeb.Components.TimeseriesPointsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Paths
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Points
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.SeriesData

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
    start = DateTime.shift(now, day: -90)

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

  test "a 24 hour window whose data covers only its last ten minutes starts the axis at the window start" do
    finish = ~U[2026-03-10 12:00:00Z]
    start = DateTime.shift(finish, day: -1)
    points = for minute <- -10..0, do: {DateTime.shift(finish, minute: minute), 20.0 + minute}

    [series] =
      SeriesData.build_series_data([{"cpu", points}],
        spec: %{y: "usage_percent"},
        time_window: {:ok, start, finish}
      )

    [{first_tick_x, first_tick_iso} | _] = series.x_ticks
    assert first_tick_iso == DateTime.to_iso8601(start)
    assert first_tick_x == series.chart_left_pad
    assert DateTime.compare(series.first_dt, start) == :eq

    usable = Paths.chart_width() - series.chart_left_pad - Paths.chart_right_pad()
    [earliest | _] = series.point_data
    assert earliest.x > series.chart_left_pad + 0.99 * usable
  end

  for {name, points, segments} <- [
        {"an evenly spaced series thinned for drawing",
         for(minute <- 0..999, do: {DateTime.shift(~U[2026-03-01 00:00:00Z], minute: minute), rem(minute, 7) * 1.0}), 1},
        {"two clusters 30 hours apart",
         for(
           cluster_start <- [~U[2026-03-01 00:00:00Z], ~U[2026-03-02 06:55:00Z]],
           step <- 0..11,
           do: {DateTime.shift(cluster_start, minute: step * 5), 40.0 + step}
         ), 2}
      ] do
    test "#{name} draws #{segments} line segment(s)" do
      [series] = SeriesData.build_series_data([{"cpu", unquote(Macro.escape(points))}], spec: %{y: "usage_percent"})

      assert length(Regex.scan(~r/M /, series.paths.line)) == unquote(segments)
    end
  end
end
