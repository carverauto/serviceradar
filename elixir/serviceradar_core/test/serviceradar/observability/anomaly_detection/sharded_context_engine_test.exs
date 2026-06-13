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
    assert length(batch) >= 1
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
