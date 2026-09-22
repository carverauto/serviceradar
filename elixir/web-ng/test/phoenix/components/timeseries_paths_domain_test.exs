defmodule ServiceRadarWebNGWeb.Components.TimeseriesPathsDomainTest do
  # Not async: the scaling test reads VM call counters for DateTime.to_unix/2.
  use ExUnit.Case, async: false

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Paths

  @moduletag :unit
  @moduletag :db_free

  defp series(count) do
    start = ~U[2026-01-01 00:00:00Z]
    for n <- 0..(count - 1), do: {DateTime.add(start, n * 60, :second), n * 1.0}
  end

  test "a precomputed domain places instants exactly where the full series does" do
    points = series(50) ++ [{nil, 3.0}, :not_a_point]
    domain = Paths.time_domain(points)

    assert domain.count == 50

    for {dt, _v} <- series(50) do
      assert Paths.datetime_to_x(dt, domain, %{}) == Paths.datetime_to_x(dt, points, %{})
    end

    before = ~U[2025-12-31 23:00:00Z]
    assert Paths.datetime_to_x(before, domain, %{}) == nil
    assert Paths.datetime_to_x(before, points, %{}) == nil
  end

  test "empty and single-point series keep their edge cases" do
    assert Paths.time_domain([]) == %{count: 0, first: nil, last: nil}
    assert Paths.datetime_to_x(~U[2026-01-01 00:00:00Z], [], %{}) == nil

    [{only, _}] = one = series(1)
    assert Paths.datetime_to_x(only, one, %{}) == Paths.datetime_to_x(only, Paths.time_domain(one), %{})
    assert is_number(Paths.datetime_to_x(only, one, %{}))
    assert Paths.datetime_to_x(~U[2026-01-01 00:05:00Z], one, %{}) == nil
  end

  test "building a chart path converts each timestamp a bounded number of times" do
    # datetime_to_x/3 used to rebuild the series' time extent on every call and
    # is called once per point, so 400 points cost 160,000 conversions and a
    # real interface chart took seconds to render. Linear work is a few per
    # point; the bound below fails loudly if the quadratic comes back.
    points = series(400)
    domain = %{min: 0.0, max: 400.0, scale: :linear}

    :erlang.trace_pattern({DateTime, :to_unix, 2}, true, [:call_count])
    :erlang.trace(self(), true, [:call])

    try do
      assert %{line: line} = Paths.chart_paths(points, domain, %{})
      assert line != ""
    after
      :erlang.trace(self(), false, [:call])
    end

    {:call_count, calls} = :erlang.trace_info({DateTime, :to_unix, 2}, :call_count)
    :erlang.trace_pattern({DateTime, :to_unix, 2}, false, [:call_count])

    assert calls > 0
    assert calls <= 400 * 6, "expected linear work, got #{calls} conversions for 400 points"
  end
end
