defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.TimeseriesCounterGapTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Metrics
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Paths

  @moduletag :unit
  @moduletag :db_free

  test "drops the first counter sample instead of plotting an artificial zero rate" do
    t0 = ~U[2026-01-01 00:00:00Z]
    t1 = DateTime.add(t0, 60, :second)

    assert [{"ifInOctets", [{^t1, 10.0}]}] =
             Metrics.counter_rates([{"ifInOctets", [{t0, 100.0}, {t1, 700.0}]}], nil)
  end

  test "marks implausible counter decreases as no-data gaps and resumes from the reset value" do
    t0 = ~U[2026-01-01 00:00:00Z]
    t1 = DateTime.add(t0, 60, :second)
    t2 = DateTime.add(t1, 60, :second)

    assert [{"ifInOctets", [{^t1, nil}, {^t2, 10.0}]}] =
             Metrics.counter_rates([{"ifInOctets", [{t0, 1_000.0}, {t1, 100.0}, {t2, 700.0}]}], nil)
  end

  test "preserves valid near-rollover decreases as rates" do
    t0 = ~U[2026-01-01 00:00:00Z]
    t1 = DateTime.add(t0, 60, :second)

    assert [{"customCounter", [{^t1, rate}]}] =
             Metrics.counter_rates(
               [{"customCounter", [{t0, 4_294_967_000.0}, {t1, 100.0}], %{counter_width: 32}}],
               nil
             )

    assert_in_delta rate, (4_294_967_295.0 - 4_294_967_000.0 + 100.0) / 60.0, 0.001
  end

  test "breaks SVG paths at nil counter-gap sentinels" do
    t0 = ~U[2026-01-01 00:00:00Z]
    t1 = DateTime.add(t0, 60, :second)
    t2 = DateTime.add(t1, 60, :second)

    paths = Paths.chart_paths([{t0, 10.0}, {t1, nil}, {t2, 20.0}], nil)

    assert paths.line =~ "M 8,76"
    assert paths.line =~ "M 792,19"
    refute paths.line =~ "L 792,8"
    refute paths.area =~ "nil"
  end
end
