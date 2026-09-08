defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.TimeseriesCounterGapTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Metrics
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Paths

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
end
