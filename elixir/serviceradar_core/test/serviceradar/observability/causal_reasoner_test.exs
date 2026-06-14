defmodule ServiceRadar.Observability.CausalReasonerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.CausalReasoner

  test "returns insufficient baseline verdict without retaining state" do
    context = %{baseline: [1.0, 2.0], min_samples: 3, window_size: 4}
    sample = %{value: 9.0, observed_at_unix_nano: 42}

    assert {:ok, first} = CausalReasoner.reason(context, sample)
    assert {:ok, second} = CausalReasoner.reason(context, sample)

    assert first == second
    assert first.state == "insufficient_baseline"
    assert first.anomalous == false
    assert first.breached == false
    assert first.include_in_baseline == true
    assert first.next_consecutive_anomalous == 0
    assert first.score == 0.0
    assert first.baseline_count == 2
    assert first.sample_value == 9.0
    assert first.observed_at_unix_nano == 42
    assert first.next_window_tail == [1.0, 2.0, 9.0]
    assert first.next_rolling_acc.count == 3
    assert_in_delta first.next_rolling_acc.mean, 4.0, 0.0001
  end

  test "accepts string-keyed contexts from decoded payloads" do
    context = %{"baseline" => [1.0, 2.0, 3.0, 4.0, 5.0], "min_samples" => 3, "window_size" => 4}
    sample = %{"value" => 3.0}

    assert {:ok, verdict} = CausalReasoner.reason(context, sample)

    assert verdict.state == "clean"
    assert verdict.anomalous == false
    assert verdict.breached == false
    assert verdict.include_in_baseline == true
    assert verdict.next_consecutive_anomalous == 0
    assert verdict.baseline_count == 4
    assert verdict.observed_at_unix_nano == nil
    assert verdict.next_window_tail == [3.0, 4.0, 5.0, 3.0]
  end

  test "withholds breached samples and waits for sustained confirmation" do
    context = %{
      baseline: [1.0, 2.0, 3.0],
      min_samples: 3,
      window_size: 3,
      n_sigma: 3.0,
      confirm_slots: 2,
      consecutive_anomalous: 1
    }

    assert {:ok, verdict} = CausalReasoner.reason(context, %{value: 5.0})

    assert verdict.state == "anomalous"
    assert verdict.anomalous == true
    assert verdict.breached == true
    assert verdict.include_in_baseline == false
    assert verdict.next_consecutive_anomalous == 2
    assert verdict.score == 3.0
    assert verdict.next_window_tail == [1.0, 2.0, 3.0]
    assert verdict.next_rolling_acc.count == 3
  end

  test "combines a seasonal baseline when rolling baseline is not ready" do
    context = %{
      "baseline" => [1.0],
      "min_samples" => 3,
      "window_size" => 4,
      "seasonal_baseline" => [10.0, 11.0, 12.0, 13.0],
      "seasonal_min_samples" => 3,
      "seasonal_n_sigma" => 2.0
    }

    assert {:ok, verdict} = CausalReasoner.reason(context, %{"value" => 30.0})

    assert verdict.state == "pending_anomaly"
    assert verdict.breached == true
    assert verdict.include_in_baseline == false
    assert Enum.any?(verdict.signals, &(&1.name == "seasonal" and &1.ready and &1.breached))
  end

  test "reuses compact rolling state without requiring the full baseline window" do
    context = %{
      baseline: [1_000_000_000.0, 1_000_000_001.0, 999_999_999.0],
      min_samples: 3,
      window_size: 3,
      n_sigma: 10.0
    }

    assert {:ok, first} = CausalReasoner.reason(context, %{value: 1_000_000_000.5})

    compact_context =
      Map.merge(context, %{
        baseline: [],
        window_tail: first.next_window_tail,
        rolling_acc: first.next_rolling_acc
      })

    assert {:ok, compact} = CausalReasoner.reason(compact_context, %{value: 1_000_000_000.25})

    assert {:ok, full} =
             CausalReasoner.reason(%{context | baseline: first.next_window_tail}, %{
               value: 1_000_000_000.25
             })

    assert compact.state == full.state
    assert_in_delta compact.score, full.score, 0.0001
    assert compact.next_window_tail == full.next_window_tail
  end

  test "reason_batch preserves input order" do
    context = %{baseline: [1.0, 2.0, 3.0], min_samples: 3, window_size: 3}

    assert [
             {:ok, %{sample_value: 3.5, next_window_tail: [2.0, 3.0, 3.5]}},
             {:ok, %{sample_value: 2.5, next_window_tail: [2.0, 3.0, 2.5]}}
           ] =
             CausalReasoner.reason_batch([
               %{context: context, sample: %{value: 3.5}},
               %{"context" => context, "sample" => %{"value" => 2.5}}
             ])
  end

  test "reason_state_batch keeps per-series rolling state in the native shard" do
    shard_state = CausalReasoner.new_shard_state()

    context = %{
      baseline: [],
      min_samples: 3,
      window_size: 3,
      n_sigma: 3.0,
      confirm_slots: 1
    }

    assert [
             {:ok, %{baseline_count: 0, state: "insufficient_baseline"}},
             {:ok, %{baseline_count: 1, state: "insufficient_baseline"}},
             {:ok, %{baseline_count: 2, state: "insufficient_baseline"}},
             {:ok, clean},
             {:ok, anomaly}
           ] =
             CausalReasoner.reason_state_batch(shard_state, [
               %{series_key: "series-a", context: context, sample: %{value: 10.0}},
               %{series_key: "series-a", context: context, sample: %{value: 11.0}},
               %{series_key: "series-a", context: context, sample: %{value: 12.0}},
               %{series_key: "series-a", context: context, sample: %{value: 11.5}},
               %{series_key: "series-a", context: context, sample: %{value: 30.0}}
             ])

    assert clean.state == "clean"
    assert clean.next_window_tail == []
    assert anomaly.anomalous == true
    assert anomaly.next_window_tail == []
  end

  test "forget_series removes native shard rolling state" do
    shard_state = CausalReasoner.new_shard_state()
    context = %{baseline: [], min_samples: 2, window_size: 3}

    assert [{:ok, %{baseline_count: 0}}, {:ok, %{baseline_count: 1}}] =
             CausalReasoner.reason_state_batch(shard_state, [
               %{series_key: "series-a", context: context, sample: %{value: 10.0}},
               %{series_key: "series-a", context: context, sample: %{value: 11.0}}
             ])

    assert CausalReasoner.forget_series(shard_state, "series-a")

    assert [{:ok, %{baseline_count: 0}}] =
             CausalReasoner.reason_state_batch(shard_state, [
               %{series_key: "series-a", context: context, sample: %{value: 12.0}}
             ])
  end

  test "reason_state_batch_events omits runtime-only state from clean results" do
    shard_state = CausalReasoner.new_shard_state()
    context = %{baseline: [], min_samples: 3, window_size: 3, confirm_slots: 1}

    assert [
             {:ok, clean},
             {:ok, _},
             {:ok, _},
             {:ok, anomaly}
           ] =
             CausalReasoner.reason_state_batch_events(shard_state, [
               %{series_key: "series-a", context: context, sample: %{value: 10.0}},
               %{series_key: "series-a", context: context, sample: %{value: 11.0}},
               %{series_key: "series-a", context: context, sample: %{value: 12.0}},
               %{series_key: "series-a", context: context, sample: %{value: 30.0}}
             ])

    refute Map.has_key?(clean, :next_window_tail)
    refute Map.has_key?(clean, :next_rolling_acc)
    assert clean.signals == []
    assert anomaly.anomalous == true
    assert anomaly.signals != []
  end

  test "reason_state_values_changes caches context and emits sparse state changes" do
    shard_state = CausalReasoner.new_shard_state()
    context = %{baseline: [], min_samples: 3, window_size: 3, confirm_slots: 1}

    assert [
             {3, {:ok, open}},
             {5, {:ok, clear}}
           ] =
             CausalReasoner.reason_state_values_changes(shard_state, [
               %{index: 0, series_key: "series-a", context: context, value: 10.0},
               %{index: 1, series_key: "series-a", context: nil, value: 11.0},
               %{index: 2, series_key: "series-a", context: nil, value: 12.0},
               %{index: 3, series_key: "series-a", context: nil, value: 30.0},
               %{index: 4, series_key: "series-a", context: nil, value: 31.0},
               %{index: 5, series_key: "series-a", context: nil, value: 11.5}
             ])

    assert open.anomalous == true
    assert clear.anomalous == false
    assert clear.breached == false
  end

  test "reason_state_value_tuples_changes accepts compact tuple inputs" do
    shard_state = CausalReasoner.new_shard_state()
    context = %{baseline: [], min_samples: 3, window_size: 3, confirm_slots: 1}

    assert [
             {3, {:ok, open}},
             {5, {:ok, clear}}
           ] =
             CausalReasoner.reason_state_value_tuples_changes(shard_state, [
               {0, "series-a", context, 10.0, nil},
               {1, "series-a", nil, 11.0, nil},
               {2, "series-a", nil, 12.0, nil},
               {3, "series-a", nil, 30.0, nil},
               {4, "series-a", nil, 31.0, nil},
               {5, "series-a", nil, 11.5, nil}
             ])

    assert open.anomalous == true
    assert clear.anomalous == false
    assert clear.breached == false
  end

  test "map and tuple state-change batch APIs stay in parity" do
    map_shard_state = CausalReasoner.new_shard_state()
    tuple_shard_state = CausalReasoner.new_shard_state()
    context = %{baseline: [], min_samples: 3, window_size: 3, confirm_slots: 1}

    map_inputs = [
      %{
        index: 0,
        series_key: "series-a",
        context: context,
        value: 10.0,
        observed_at_unix_nano: 1
      },
      %{index: 1, series_key: "series-a", context: nil, value: 11.0, observed_at_unix_nano: 2},
      %{index: 2, series_key: "series-a", context: nil, value: 12.0, observed_at_unix_nano: 3},
      %{index: 3, series_key: "series-a", context: nil, value: 30.0, observed_at_unix_nano: 4},
      %{index: 4, series_key: "series-a", context: nil, value: 31.0, observed_at_unix_nano: 5},
      %{index: 5, series_key: "series-a", context: nil, value: 11.5, observed_at_unix_nano: 6}
    ]

    tuple_inputs =
      Enum.map(map_inputs, fn input ->
        {input.index, input.series_key, input.context, input.value, input.observed_at_unix_nano}
      end)

    assert CausalReasoner.reason_state_values_changes(map_shard_state, map_inputs) ==
             CausalReasoner.reason_state_value_tuples_changes(tuple_shard_state, tuple_inputs)
  end
end
