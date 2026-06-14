defmodule ServiceRadar.Observability.AnomalyDetection.ShardedContextEngineTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.AnomalyDetection.ShardedContextEngine
  alias ServiceRadar.Observability.CausalReasoner

  setup do
    previous_reasoner = Application.get_env(:serviceradar_core, :anomaly_detection_reasoner)
    previous_shard_count = Application.get_env(:serviceradar_core, :anomaly_detection_shard_count)
    previous_test_pid = Application.get_env(:serviceradar_core, :sharded_context_engine_test_pid)

    Application.put_env(:serviceradar_core, :anomaly_detection_reasoner, __MODULE__.BatchReasoner)
    Application.put_env(:serviceradar_core, :anomaly_detection_shard_count, 2)
    Application.put_env(:serviceradar_core, :sharded_context_engine_test_pid, self())

    on_exit(fn ->
      restore_env(:anomaly_detection_reasoner, previous_reasoner)
      restore_env(:anomaly_detection_shard_count, previous_shard_count)
      restore_env(:sharded_context_engine_test_pid, previous_test_pid)
    end)

    :ok
  end

  test "evaluates independent series through reason_batch" do
    start_supervised!({ShardedContextEngine, shard_count: 2})

    results =
      ShardedContextEngine.evaluate_batch([
        sample("series-a", "a1", 1, 10.0),
        sample("series-b", "b1", 1, 20.0)
      ])

    assert [{:ok, %{state: "clean"}}, {:ok, %{state: "clean"}}] = results
    assert_receive {:reason_batch, batch}
    refute Enum.empty?(batch)
  end

  test "preserves same-series order by splitting dependent samples across batches" do
    start_supervised!({ShardedContextEngine, shard_count: 1})

    results =
      ShardedContextEngine.evaluate_batch([
        sample("series-a", "a1", 1, 10.0),
        sample("series-a", "a2", 2, 11.0),
        sample("series-b", "b1", 1, 20.0)
      ])

    assert [{:ok, _}, {:ok, _}, {:ok, _}] = results
    assert_receive {:reason_batch, first_batch}
    assert_receive {:reason_batch, second_batch}

    assert Enum.map(first_batch, fn {_context, sample} -> sample.value end) == [10.0, 20.0]
    assert Enum.map(second_batch, fn {_context, sample} -> sample.value end) == [11.0]
  end

  test "reports missing series keys without crashing the shard" do
    start_supervised!({ShardedContextEngine, shard_count: 1})

    assert [{:error, :missing_series_key}] =
             ShardedContextEngine.evaluate_batch([%{value: 10.0, observed_at_unix_nano: 1}])
  end

  test "native event path skips already committed event IDs on redelivery" do
    Application.put_env(:serviceradar_core, :anomaly_detection_reasoner, CausalReasoner)

    start_supervised!(
      {ShardedContextEngine, shard_count: 1, min_samples: 3, window_size: 3, confirm_slots: 1}
    )

    samples = [
      sample("series-redelivery", "r1", 1, 10.0),
      sample("series-redelivery", "r2", 2, 11.0),
      sample("series-redelivery", "r3", 3, 12.0),
      sample("series-redelivery", "r4", 4, 30.0)
    ]

    assert [{%{event_id: "r4"}, {:ok, %{anomalous: true}}}] =
             ShardedContextEngine.evaluate_events_batch(samples)

    assert Enum.all?(ShardedContextEngine.evaluate_events_batch(samples), fn
             {_sample, {:drop, :duplicate_event}} -> true
             _other -> false
           end)
  end

  test "evicts down to the cap (not just one) when a batch adds many new series" do
    Application.put_env(
      :serviceradar_core,
      :anomaly_detection_reasoner,
      __MODULE__.NativeReasoner
    )

    # Single shard so every series lands on the same shard map; small cap so the
    # batch overflows it by far more than one.
    start_supervised!({ShardedContextEngine, shard_count: 1, max_series: 3})

    samples =
      Enum.map(1..20, fn n ->
        sample("series-#{n}", "e#{n}", n, n * 1.0)
      end)

    results = ShardedContextEngine.evaluate_batch(samples)
    assert length(results) == 20
    assert Enum.all?(results, &match?({:ok, _}, &1))

    # The cap is enforced in a single pass: the shard holds exactly max_series,
    # not max_series + (batch_size - 1) as the old one-key-per-batch eviction did.
    shard_state = :sys.get_state(ShardedContextEngine.shard_name(0))
    assert map_size(shard_state.series) == 3

    # Every evicted series must be forgotten in the NIF so the native guard stays
    # in sync; 20 added - 3 retained = 17 forgets.
    forgotten = drain_forgets()
    assert length(forgotten) == 17
  end

  test "intra-batch duplicate event_id folds the native series state once" do
    Application.put_env(
      :serviceradar_core,
      :anomaly_detection_reasoner,
      __MODULE__.NativeReasoner
    )

    start_supervised!({ShardedContextEngine, shard_count: 1, max_series: 100})

    # Two samples in the SAME batch carry the same event_id for the same series.
    # Only the first may fold into the NIF; the second must be dropped as a
    # duplicate before any native input is built.
    samples = [
      sample("series-dup", "shared", 1, 10.0),
      sample("series-dup", "shared", 1, 10.0)
    ]

    results = ShardedContextEngine.evaluate_events_batch(samples)

    assert [{_first, _first_result}, {_second, {:drop, :duplicate_event}}] = results

    # Exactly one sample reached the native reasoner for this series.
    native_inputs = drain_native_value_changes()
    folded_for_series = Enum.filter(native_inputs, &(&1.series_key == "series-dup"))
    assert length(folded_for_series) == 1
  end

  defp drain_forgets(acc \\ []) do
    receive do
      {:forget_series, key} -> drain_forgets([key | acc])
    after
      0 -> acc
    end
  end

  defp drain_native_value_changes(acc \\ []) do
    receive do
      {:reason_state_values_changes, inputs} -> drain_native_value_changes(acc ++ inputs)
    after
      0 -> acc
    end
  end

  defmodule NativeReasoner do
    @moduledoc """
    Native-path test double: activates the in-NIF rolling-state code paths of the
    sharded engine (new_shard_state/0 + reason_state_batch/2) and records
    forget_series/2 and reason_state_values_changes/2 calls back to the test pid.
    """

    def new_shard_state, do: make_ref()

    def reason_state_batch(_shard_state, inputs) do
      Enum.map(inputs, fn _input -> {:ok, clean_verdict()} end)
    end

    def reason_state_values_changes(_shard_state, inputs) do
      send(
        Application.fetch_env!(:serviceradar_core, :sharded_context_engine_test_pid),
        {:reason_state_values_changes, inputs}
      )

      # Emit a single clean state-change verdict per input so the engine commits
      # event ids; index mirrors the native indexed-result contract.
      Enum.map(inputs, fn input -> {input.index, {:ok, clean_verdict()}} end)
    end

    def forget_series(_shard_state, key) do
      send(
        Application.fetch_env!(:serviceradar_core, :sharded_context_engine_test_pid),
        {:forget_series, key}
      )

      :ok
    end

    defp clean_verdict do
      %{
        state: "clean",
        anomalous: false,
        include_in_baseline: true,
        next_consecutive_anomalous: 0,
        next_window_tail: [],
        next_rolling_acc: %{count: 0, mean: 0.0, m2: 0.0}
      }
    end
  end

  defmodule BatchReasoner do
    @moduledoc false

    def reason_batch(inputs) do
      send(Application.fetch_env!(:serviceradar_core, :sharded_context_engine_test_pid), {
        :reason_batch,
        inputs
      })

      Enum.map(inputs, fn {context, sample} ->
        tail =
          context
          |> Map.get(:window_tail, [])
          |> Kernel.++([sample.value])
          |> Enum.take(-context.window_size)

        {:ok,
         %{
           state: "clean",
           anomalous: false,
           include_in_baseline: true,
           next_consecutive_anomalous: 0,
           next_window_tail: tail,
           next_rolling_acc: rolling_acc(tail)
         }}
      end)
    end

    defp rolling_acc([]), do: %{count: 0, mean: 0.0, m2: 0.0}

    defp rolling_acc(values) do
      count = length(values)
      mean = Enum.sum(values) / count
      m2 = values |> Enum.map(&((&1 - mean) * (&1 - mean))) |> Enum.sum()
      %{count: count, mean: mean, m2: m2}
    end
  end

  defp sample(series_key, event_id, order, value) do
    %{
      series_key: series_key,
      event_id: event_id,
      order_key: {order, event_id},
      value: value,
      observed_at_unix_nano: order,
      subject: "otel.metrics.derived",
      metric_class: "test"
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
