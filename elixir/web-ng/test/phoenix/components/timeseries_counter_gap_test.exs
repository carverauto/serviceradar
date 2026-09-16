defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.TimeseriesCounterGapTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Metrics
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Paths
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Points
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.SeriesData

  @moduletag :unit
  @moduletag :db_free

  setup_all do
    Application.ensure_all_started(:telemetry)
    :ok
  end

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

  test "emits counted telemetry for withheld counter-rate samples" do
    handler_id = "timeseries-counter-drop-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler_id,
      [:serviceradar, :web_ng, :timeseries, :counter_rate, :dropped],
      &__MODULE__.handle_counter_rate_drop/4,
      parent
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    t0 = ~U[2026-01-01 00:00:00Z]
    t1 = DateTime.add(t0, 60, :second)

    assert [{"ifInOctets", [{^t1, nil}]}] =
             Metrics.counter_rates(
               [{"ifInOctets", [{t0, 1_000.0}, {t1, 100.0}], %{counter_width: 32}}],
               nil
             )

    assert_receive {:counter_rate_drop, _event, %{count: 1}, %{series: "ifInOctets", reason: :warmup, counter_width: 32}}

    assert_receive {:counter_rate_drop, _event, %{count: 1},
                    %{series: "ifInOctets", reason: :counter_decrease, counter_width: 32}}
  end

  def handle_counter_rate_drop(event, measurements, metadata, pid) do
    send(pid, {:counter_rate_drop, event, measurements, metadata})
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

    assert paths.line =~ "M 70.00,69.00 L 74.00,69.00"
    assert paths.line =~ "M 766.00,21.00 L 770.00,21.00"
    refute paths.line =~ "L 768,12"
    refute paths.area =~ "nil"
  end

  test "positions irregularly sampled points by timestamp instead of array index" do
    t0 = ~U[2026-01-01 00:00:00Z]
    t1 = DateTime.add(t0, 60, :second)
    t2 = DateTime.add(t0, 600, :second)
    points = [{t0, 1.0}, {t1, 2.0}, {t2, 3.0}]

    assert Paths.datetime_to_x(t1, points) == 141.6
    assert Paths.chart_paths(points, nil).line =~ "141.60"
  end

  test "known bucket duration breaks sparse charts across missing measurements" do
    first = ~U[2034-01-01 00:00:00Z]
    last = DateTime.add(first, 12, :hour)
    points = [{first, 10.0}, {last, 40.0}]

    [series] = SeriesData.build_series_data([{"cpu", points}], bucket_seconds: 60)

    assert length(String.split(series.paths.line, "M ")) == 3
    assert length(String.split(series.paths.area, "M ")) == 3
    assert series.paths.avg == 25.0
    assert series.paths.latest == 40.0
    assert Enum.map(series.point_data, & &1.v) == [10.0, 40.0]
    assert Points.time_gaps(points) == []
  end

  test "fine query buckets keep regular slower interface polling connected without bridging outages" do
    start = ~U[2034-01-01 00:00:00Z]
    regular = for minute <- 0..59, do: {DateTime.add(start, minute, :minute), rem(minute, 7) * 1.0}
    later = for minute <- 780..839, do: {DateTime.add(start, minute, :minute), rem(minute, 7) * 1.0}

    [continuous] = SeriesData.build_series_data([{"ifInOctets", regular}], bucket_seconds: 15)
    [interrupted] = SeriesData.build_series_data([{"ifInOctets", regular ++ later}], bucket_seconds: 15)

    assert continuous.time_gaps == []
    assert length(String.split(continuous.paths.line, "M ")) == 2
    assert length(interrupted.time_gaps) == 1
    assert length(String.split(interrupted.paths.line, "M ")) == 3
    assert length(String.split(interrupted.paths.area, "M ")) == 3
    assert Enum.map(continuous.point_data, & &1.v) == Enum.map(regular, &elem(&1, 1))
  end

  test "long missing intervals break individual and combined lines using observed cadence" do
    start = ~U[2034-01-01 00:00:00Z]
    points = for seconds <- [0, 60, 43_200, 43_260], do: {DateTime.add(start, seconds), 20.0}

    series = SeriesData.build_series_data([{"cpu-a", points}, {"cpu-b", points}], [])
    assert Enum.all?(series, &(length(String.split(&1.paths.line, "M ")) == 3))

    assert {[combined], []} = SeriesData.resolve_chart_groups(series, true, :single, nil, false, "CPU")
    assert Enum.all?(combined.series, &(length(String.split(&1.paths.line, "M ")) == 3))
  end

  test "display decimation retains real gaps without mistaking omitted display points for outages" do
    start = ~U[2034-01-01 00:00:00Z]
    regular = for minute <- 0..999, do: {DateTime.add(start, minute, :minute), rem(minute, 7) * 1.0}
    later = for minute <- 2_000..2_999, do: {DateTime.add(start, minute, :minute), rem(minute, 7) * 1.0}

    [continuous] = SeriesData.build_series_data([{"cpu", regular}], bucket_seconds: 60)
    [interrupted] = SeriesData.build_series_data([{"cpu", regular ++ later}], bucket_seconds: 60)

    assert length(continuous.raw_points) <= 800
    assert length(interrupted.raw_points) <= 800
    assert length(String.split(continuous.paths.line, "M ")) == 2
    assert length(String.split(interrupted.paths.line, "M ")) == 3
    assert length(String.split(interrupted.paths.area, "M ")) == 3
  end
end
