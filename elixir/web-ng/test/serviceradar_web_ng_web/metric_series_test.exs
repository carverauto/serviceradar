defmodule ServiceRadarWebNGWeb.MetricSeriesTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.MetricSeries

  defp point(overrides) do
    Map.merge(
      %{
        "timestamp" => "2026-06-10T12:00:00Z",
        "metric_name" => "test.metric",
        "metric_type" => "sum",
        "temporality" => "cumulative",
        "is_monotonic" => true,
        "unit" => "1",
        "service_name" => "svc",
        "attributes" => ~s({"queue":"0"}),
        "attributes_hash" => "hash-a",
        "value" => 0.0
      },
      overrides
    )
  end

  describe "series/1 — cumulative monotonic sums (rate)" do
    test "computes per-interval rates as delta / Δt seconds" do
      points = [
        point(%{"timestamp" => "2026-06-10T12:00:00Z", "value" => 10.0}),
        point(%{"timestamp" => "2026-06-10T12:01:00Z", "value" => 70.0}),
        point(%{"timestamp" => "2026-06-10T12:02:00Z", "value" => 130.0})
      ]

      assert [series] = MetricSeries.series(points)
      assert series.kind == :rate
      assert series.metric_type == "sum"
      assert series.temporality == "cumulative"
      assert series.point_count == 3
      assert series.rates == [1.0, 1.0]
      assert series.current_rate == 1.0
    end

    test "detects counter resets and uses the new value as the delta" do
      points = [
        point(%{"timestamp" => "2026-06-10T12:00:00Z", "value" => 10.0}),
        point(%{"timestamp" => "2026-06-10T12:01:00Z", "value" => 70.0}),
        # reset: value decreased -> delta is the new value (5), not 5 - 70
        point(%{"timestamp" => "2026-06-10T12:02:00Z", "value" => 5.0})
      ]

      assert [series] = MetricSeries.series(points)
      assert series.rates == [1.0, 5.0 / 60.0]
      assert series.current_rate == 5.0 / 60.0
    end

    test "sorts out-of-order timestamps before pairing" do
      points = [
        point(%{"timestamp" => "2026-06-10T12:02:00Z", "value" => 130.0}),
        point(%{"timestamp" => "2026-06-10T12:00:00Z", "value" => 10.0}),
        point(%{"timestamp" => "2026-06-10T12:01:00Z", "value" => 70.0})
      ]

      assert [series] = MetricSeries.series(points)
      assert series.rates == [1.0, 1.0]
    end

    test "single-point series yields no rate" do
      assert [series] = MetricSeries.series([point(%{"value" => 42.0})])
      assert series.kind == :rate
      assert series.rates == []
      assert series.current_rate == nil
    end

    test "skips pairs with zero or negative Δt" do
      points = [
        point(%{"timestamp" => "2026-06-10T12:00:00Z", "value" => 10.0}),
        point(%{"timestamp" => "2026-06-10T12:00:00Z", "value" => 20.0}),
        point(%{"timestamp" => "2026-06-10T12:01:00Z", "value" => 80.0})
      ]

      assert [series] = MetricSeries.series(points)
      # Only the 12:00 -> 12:01 pair produces a rate: (80 - 20) / 60s.
      assert series.rates == [1.0]
    end

    test "unspecified temporality with monotonic counter still rates defensively" do
      points = [
        point(%{"timestamp" => "2026-06-10T12:00:00Z", "temporality" => "unspecified", "value" => 0.0}),
        point(%{"timestamp" => "2026-06-10T12:00:30Z", "temporality" => "unspecified", "value" => 30.0})
      ]

      assert [series] = MetricSeries.series(points)
      assert series.kind == :rate
      assert series.rates == [1.0]
    end
  end

  describe "series/1 — delta sums" do
    test "sums point values over the window" do
      points = [
        point(%{"timestamp" => "2026-06-10T12:00:00Z", "temporality" => "delta", "value" => 5.0}),
        point(%{"timestamp" => "2026-06-10T12:01:00Z", "temporality" => "delta", "value" => 7.0}),
        point(%{"timestamp" => "2026-06-10T12:02:00Z", "temporality" => "delta", "value" => 9.0})
      ]

      assert [series] = MetricSeries.series(points)
      assert series.kind == :delta_sum
      assert series.window_sum == 21.0
      assert series.values == [5.0, 7.0, 9.0]
    end
  end

  describe "series/1 — gauges" do
    test "keeps the chronologically last value even with descending input" do
      points = [
        point(%{
          "timestamp" => "2026-06-10T12:02:00Z",
          "metric_type" => "gauge",
          "temporality" => nil,
          "value" => 3.5
        }),
        point(%{
          "timestamp" => "2026-06-10T12:00:00Z",
          "metric_type" => "gauge",
          "temporality" => nil,
          "value" => 1.0
        })
      ]

      assert [series] = MetricSeries.series(points)
      assert series.kind == :gauge
      assert series.last_value == 3.5
      assert series.values == [1.0, 3.5]
    end

    test "non-monotonic cumulative sums fall back to gauge semantics" do
      points = [
        point(%{"timestamp" => "2026-06-10T12:00:00Z", "is_monotonic" => false, "value" => 9.0}),
        point(%{"timestamp" => "2026-06-10T12:01:00Z", "is_monotonic" => false, "value" => 4.0})
      ]

      assert [series] = MetricSeries.series(points)
      assert series.kind == :gauge
      assert series.last_value == 4.0
    end
  end

  describe "series/1 — histograms" do
    test "cumulative histograms report the latest count/sum snapshot" do
      points = [
        point(%{
          "timestamp" => "2026-06-10T12:00:00Z",
          "metric_type" => "histogram",
          "value" => nil,
          "count" => 10,
          "sum" => 100.0
        }),
        point(%{
          "timestamp" => "2026-06-10T12:01:00Z",
          "metric_type" => "histogram",
          "value" => nil,
          "count" => 14,
          "sum" => 180.0
        })
      ]

      assert [series] = MetricSeries.series(points)
      assert series.kind == :histogram
      assert series.histogram_count == 14
      assert series.histogram_sum == 180.0
    end

    test "delta histograms sum counts and sums over the window" do
      points = [
        point(%{
          "timestamp" => "2026-06-10T12:00:00Z",
          "metric_type" => "histogram",
          "temporality" => "delta",
          "value" => nil,
          "count" => 3,
          "sum" => 30.0
        }),
        point(%{
          "timestamp" => "2026-06-10T12:01:00Z",
          "metric_type" => "histogram",
          "temporality" => "delta",
          "value" => nil,
          "count" => 4,
          "sum" => 50.0
        })
      ]

      assert [series] = MetricSeries.series(points)
      assert series.histogram_count == 7
      assert series.histogram_sum == 80.0
    end
  end

  describe "series/1 — grouping and defensiveness" do
    test "groups points into one series per attributes_hash" do
      points = [
        point(%{"attributes_hash" => "hash-a", "timestamp" => "2026-06-10T12:00:00Z", "value" => 1.0}),
        point(%{"attributes_hash" => "hash-b", "timestamp" => "2026-06-10T12:00:00Z", "value" => 2.0}),
        point(%{"attributes_hash" => "hash-a", "timestamp" => "2026-06-10T12:01:00Z", "value" => 61.0})
      ]

      assert [a, b] = MetricSeries.series(points)
      assert a.attributes_hash == "hash-a"
      assert a.point_count == 2
      assert b.attributes_hash == "hash-b"
      assert b.point_count == 1
    end

    test "ignores points with unparseable timestamps for rate math" do
      points = [
        point(%{"timestamp" => "not-a-timestamp", "value" => 5.0}),
        point(%{"timestamp" => "2026-06-10T12:00:00Z", "value" => 10.0}),
        point(%{"timestamp" => "2026-06-10T12:01:00Z", "value" => 70.0})
      ]

      assert [series] = MetricSeries.series(points)
      assert series.point_count == 3
      assert series.rates == [1.0]
    end

    test "handles non-list and non-map input without raising" do
      assert MetricSeries.series(nil) == []
      assert MetricSeries.series([nil, "junk", 42]) == []
    end
  end

  describe "rates/1" do
    test "is exposed for direct unit use" do
      assert MetricSeries.rates([{0, 0.0}, {60_000_000, 60.0}]) == [1.0]
      assert MetricSeries.rates([{0, 0.0}]) == []
      assert MetricSeries.rates(:nope) == []
    end
  end
end
