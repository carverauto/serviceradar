defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.TimeseriesCounterAxisTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Metrics
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Paths
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.SeriesData

  @moduletag :unit
  @moduletag :db_free

  test "clamps interface octet counters to link speed but not packet/error counters" do
    t0 = ~U[2026-01-01 00:00:00Z]
    t1 = DateTime.add(t0, 60, :second)

    assert [
             {"ifInOctets", [{^t1, 100.0}]},
             {"ifInErrors", [{^t1, 1_000.0}]}
           ] =
             Metrics.counter_rates(
               [
                 {"ifInOctets", [{t0, 0.0}, {t1, 60_000.0}]},
                 {"ifInErrors", [{t0, 0.0}, {t1, 60_000.0}]}
               ],
               100.0
             )
  end

  test "keeps byte-rate and count-rate counter series on separate axes when combining" do
    t0 = ~U[2026-01-01 00:00:00Z]
    t1 = DateTime.add(t0, 60, :second)
    t2 = DateTime.add(t1, 60, :second)

    rates =
      Metrics.counter_rates(
        [
          {"ifInOctets", [{t0, 0.0}, {t1, 6_000.0}, {t2, 12_000.0}]},
          {"ifOutOctets", [{t0, 0.0}, {t1, 3_000.0}, {t2, 6_000.0}]},
          {"ifInErrors", [{t0, 0.0}, {t1, 600.0}, {t2, 1_200.0}]}
        ],
        100.0
      )

    series_data = SeriesData.build_series_data(rates, %{}, :counter, false, 100.0, [], [], :linear)

    assert {[combined], [error_series]} =
             SeriesData.resolve_chart_groups(series_data, true, :combined, 100.0, false, "All counters", :linear)

    assert combined.unit == :bytes_per_sec
    assert Enum.map(combined.series, & &1.raw_series) == ["ifInOctets", "ifOutOctets"]
    assert error_series.raw_series == "ifInErrors"
    assert error_series.unit == :count_per_sec
  end

  test "widens chart left pad for long y-axis tick labels" do
    assert Paths.chart_left_pad([{100, "123456789012345"}]) > Paths.chart_left_pad()
  end

  test "uses the computed chart left pad for ticks and hover point coordinates" do
    t0 = ~U[2026-01-01 00:00:00Z]
    t1 = DateTime.add(t0, 60, :second)

    [series] =
      SeriesData.build_series_data(
        [{"custom.metric", [{t0, 0.0}, {t1, 1_000_000_000.0}]}],
        %{},
        :none,
        false,
        nil,
        [],
        [],
        :linear
      )

    assert [{first_x, _label} | _] = series.x_ticks
    assert first_x == series.chart_left_pad
    assert hd(series.point_data).x == series.chart_left_pad
  end
end
