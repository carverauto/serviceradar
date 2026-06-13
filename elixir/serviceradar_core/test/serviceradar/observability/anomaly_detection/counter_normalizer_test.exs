defmodule ServiceRadar.Observability.AnomalyDetection.CounterNormalizerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.AnomalyDetection.CounterNormalizer

  @second 1_000_000_000

  setup do
    table = :ets.new(:counter_normalizer_test, [:set, :private])

    {:ok, table: table}
  end

  test "passes gauges through unchanged", %{table: table} do
    sample = sample(value: 42, metadata: %{metric_type: "gauge"})

    assert {:ok, ^sample} = CounterNormalizer.normalize_sample(sample, table)
  end

  test "drops the first cumulative counter sample and emits rate for the next", %{table: table} do
    first = counter_sample(value: 1_000, timestamp: 10 * @second)
    second = counter_sample(value: 1_600, timestamp: 70 * @second)

    assert {:drop, :counter_warmup} = CounterNormalizer.normalize_sample(first, table)
    assert {:ok, normalized} = CounterNormalizer.normalize_sample(second, table)

    assert normalized.value == 10.0
    assert normalized.metadata.counter_normalized == true
    assert normalized.metadata.counter_delta == 600
    assert normalized.metadata.counter_elapsed_seconds == 60.0
    assert normalized.metadata.counter_raw_value == 1_600
    assert normalized.metadata.counter_rate_unit == "By/s"
  end

  test "drops reset intervals when the reset anchor changes", %{table: table} do
    first = counter_sample(value: 1_000, timestamp: 10 * @second, reset_anchor: 100)
    second = counter_sample(value: 100, timestamp: 70 * @second, reset_anchor: 200)
    third = counter_sample(value: 700, timestamp: 130 * @second, reset_anchor: 200)

    assert {:drop, :counter_warmup} = CounterNormalizer.normalize_sample(first, table)
    assert {:drop, :counter_reset} = CounterNormalizer.normalize_sample(second, table)
    assert {:ok, normalized} = CounterNormalizer.normalize_sample(third, table)

    assert normalized.value == 10.0
    assert normalized.metadata.counter_delta == 600
  end

  test "treats 64-bit decreases as reset-invalid intervals", %{table: table} do
    first = counter_sample(value: 5_000, timestamp: 10 * @second, width: 64)
    second = counter_sample(value: 100, timestamp: 70 * @second, width: 64)

    assert {:drop, :counter_warmup} = CounterNormalizer.normalize_sample(first, table)
    assert {:drop, :counter64_decrease} = CounterNormalizer.normalize_sample(second, table)
  end

  test "uses corroborated 32-bit wrap when width and rate make it plausible", %{table: table} do
    first = counter_sample(value: 4_294_967_000, timestamp: 10 * @second, width: 32)
    second = counter_sample(value: 304, timestamp: 20 * @second, width: 32)

    assert {:drop, :counter_warmup} = CounterNormalizer.normalize_sample(first, table)
    assert {:ok, normalized} = CounterNormalizer.normalize_sample(second, table)

    assert normalized.metadata.counter_delta == 600
    assert normalized.value == 60.0
  end

  test "drops 32-bit decreases when configured max rate rules out wrap", %{table: table} do
    first =
      counter_sample(
        value: 4_294_967_000,
        timestamp: 10 * @second,
        width: 32,
        max_rate: 10
      )

    second = counter_sample(value: 304, timestamp: 20 * @second, width: 32, max_rate: 10)

    assert {:drop, :counter_warmup} = CounterNormalizer.normalize_sample(first, table)
    assert {:drop, :counter_decrease} = CounterNormalizer.normalize_sample(second, table)
  end

  test "drops intervals that exceed max gap and resumes from the new point", %{table: table} do
    first = counter_sample(value: 100, timestamp: 10 * @second)
    second = counter_sample(value: 700, timestamp: 4_000 * @second)
    third = counter_sample(value: 1_300, timestamp: 4_060 * @second)

    assert {:drop, :counter_warmup} = CounterNormalizer.normalize_sample(first, table)

    assert {:drop, :counter_max_gap} =
             CounterNormalizer.normalize_sample(second, table, max_gap_ns: 600 * @second)

    assert {:ok, normalized} = CounterNormalizer.normalize_sample(third, table)
    assert normalized.value == 10.0
  end

  test "drops out-of-order counter samples without replacing current state", %{table: table} do
    first = counter_sample(value: 100, timestamp: 10 * @second)
    stale = counter_sample(value: 130, timestamp: 9 * @second)
    second = counter_sample(value: 700, timestamp: 70 * @second)

    assert {:drop, :counter_warmup} = CounterNormalizer.normalize_sample(first, table)
    assert {:drop, :counter_non_monotonic_time} = CounterNormalizer.normalize_sample(stale, table)
    assert {:ok, normalized} = CounterNormalizer.normalize_sample(second, table)

    assert normalized.value == 10.0
  end

  test "keeps integer precision for large raw counters", %{table: table} do
    first = counter_sample(value: 9_007_199_254_740_993, timestamp: 10 * @second, width: 64)
    second = counter_sample(value: 9_007_199_254_741_093, timestamp: 20 * @second, width: 64)

    assert {:drop, :counter_warmup} = CounterNormalizer.normalize_sample(first, table)
    assert {:ok, normalized} = CounterNormalizer.normalize_sample(second, table)

    assert normalized.metadata.counter_delta == 100
    assert normalized.value == 10.0
  end

  test "prefers raw_value metadata over rounded float storage value", %{table: table} do
    first =
      counter_sample(
        value: 0.0,
        raw_value: "9007199254740993",
        timestamp: 10 * @second,
        width: 64
      )

    second =
      counter_sample(
        value: 0.0,
        raw_value: "9007199254741093",
        timestamp: 20 * @second,
        width: 64
      )

    assert {:drop, :counter_warmup} = CounterNormalizer.normalize_sample(first, table)
    assert {:ok, normalized} = CounterNormalizer.normalize_sample(second, table)

    assert normalized.metadata.counter_delta == 100
    assert normalized.value == 10.0
  end

  defp counter_sample(opts) do
    metadata =
      %{
        metric_type: "sum",
        temporality: "cumulative",
        is_monotonic: true,
        unit: "By"
      }
      |> maybe_put(:start_time_unix_nano, Keyword.get(opts, :reset_anchor))
      |> maybe_put(:counter_width, Keyword.get(opts, :width))
      |> maybe_put(:max_counter_rate_per_second, Keyword.get(opts, :max_rate))
      |> maybe_put(:raw_value, Keyword.get(opts, :raw_value))

    sample(
      value: Keyword.fetch!(opts, :value),
      timestamp: Keyword.fetch!(opts, :timestamp),
      metadata: metadata
    )
  end

  defp sample(opts) do
    %{
      series_key: Keyword.get(opts, :series_key, "counter:bytes:agent-1"),
      event_id: Keyword.get(opts, :event_id, "event-#{Keyword.get(opts, :timestamp, 0)}"),
      order_key: {Keyword.get(opts, :timestamp, 0), Keyword.get(opts, :event_id, "event")},
      value: Keyword.fetch!(opts, :value),
      observed_at_unix_nano: Keyword.get(opts, :timestamp, 10 * @second),
      subject: "otel.metrics.raw",
      metric_class: "otel.metric_point",
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
