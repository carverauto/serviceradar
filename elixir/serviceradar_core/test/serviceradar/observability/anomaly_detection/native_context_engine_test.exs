defmodule ServiceRadar.Observability.AnomalyDetection.NativeContextEngineTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.AnomalyDetection.NativeContextEngine

  test "evaluates sparse state changes through native shard resources" do
    start_supervised!(
      {NativeContextEngine, shard_count: 2, min_samples: 3, window_size: 3, confirm_slots: 1}
    )

    samples = [
      sample("series-a", 0, 10.0),
      sample("series-a", 1, 11.0),
      sample("series-a", 2, 12.0),
      sample("series-a", 3, 30.0),
      sample("series-a", 4, 31.0),
      sample("series-a", 5, 11.5)
    ]

    assert [
             {%{series_key: "series-a", observed_at_unix_nano: 3}, {:ok, open}},
             {%{series_key: "series-a", observed_at_unix_nano: 5}, {:ok, clear}}
           ] = NativeContextEngine.evaluate_events_batch(samples)

    assert open.anomalous == true
    assert clear.anomalous == false
    assert clear.breached == false
  end

  test "skips already committed event IDs on redelivery" do
    start_supervised!(
      {NativeContextEngine, shard_count: 1, min_samples: 3, window_size: 3, confirm_slots: 1}
    )

    samples = [
      sample("series-redelivery", 0, 10.0),
      sample("series-redelivery", 1, 11.0),
      sample("series-redelivery", 2, 12.0),
      sample("series-redelivery", 3, 30.0)
    ]

    assert [{%{series_key: "series-redelivery"}, {:ok, %{anomalous: true}}}] =
             NativeContextEngine.evaluate_events_batch(samples)

    assert Enum.all?(NativeContextEngine.evaluate_events_batch(samples), fn
             {_sample, {:drop, :duplicate_event}} -> true
             _other -> false
           end)
  end

  test "compact event path matches map sparse state changes" do
    samples = [
      sample("series-compact", 0, 10.0),
      sample("series-compact", 1, 11.0),
      sample("series-compact", 2, 12.0),
      sample("series-compact", 3, 30.0),
      sample("series-compact", 4, 31.0),
      sample("series-compact", 5, 11.5)
    ]

    start_supervised!(
      {NativeContextEngine, shard_count: 2, min_samples: 3, window_size: 3, confirm_slots: 1}
    )

    map_results = NativeContextEngine.evaluate_events_batch(samples)
    stop_supervised!(NativeContextEngine)

    start_supervised!(
      {NativeContextEngine, shard_count: 2, min_samples: 3, window_size: 3, confirm_slots: 1}
    )

    compact_results =
      samples
      |> Enum.with_index()
      |> Enum.map(fn {sample, index} -> compact_sample(sample, index) end)
      |> NativeContextEngine.evaluate_compact_events_batch()

    assert Enum.map(map_results, fn {sample, result} ->
             {sample.observed_at_unix_nano, result}
           end) ==
             Enum.map(compact_results, fn
               {{_index, _series_key, _event_key, _value, observed_at, _config}, result} ->
                 {observed_at, result}
             end)
  end

  test "compact event path skips already committed event IDs on redelivery" do
    start_supervised!(
      {NativeContextEngine, shard_count: 1, min_samples: 3, window_size: 3, confirm_slots: 1}
    )

    samples =
      [
        sample("series-compact-redelivery", 0, 10.0),
        sample("series-compact-redelivery", 1, 11.0),
        sample("series-compact-redelivery", 2, 12.0),
        sample("series-compact-redelivery", 3, 30.0)
      ]
      |> Enum.with_index()
      |> Enum.map(fn {sample, index} -> compact_sample(sample, index) end)

    assert [
             {{_index, "series-compact-redelivery", _event_key, _value, _observed_at, _config},
              {:ok, %{anomalous: true}}}
           ] =
             NativeContextEngine.evaluate_compact_events_batch(samples)

    assert Enum.all?(NativeContextEngine.evaluate_compact_events_batch(samples), fn
             {_sample, {:drop, :duplicate_event}} -> true
             _other -> false
           end)
  end

  test "prepared shard batches match sparse state changes without regrouping samples" do
    start_supervised!(
      {NativeContextEngine, shard_count: 2, min_samples: 3, window_size: 3, confirm_slots: 1}
    )

    key = "series-prepared"
    shard_index = :erlang.phash2(key, 2)
    context = %{baseline: [], min_samples: 3, window_size: 3, confirm_slots: 1}

    assert [
             {3, {:ok, open}},
             {5, {:ok, clear}}
           ] =
             NativeContextEngine.evaluate_prepared_shard_batches([
               {shard_index,
                [
                  {0, key, context, 10.0, 0},
                  {1, key, nil, 11.0, 1},
                  {2, key, nil, 12.0, 2},
                  {3, key, nil, 30.0, 3},
                  {4, key, nil, 31.0, 4},
                  {5, key, nil, 11.5, 5}
                ]}
             ])

    assert open.anomalous == true
    assert clear.anomalous == false
    assert clear.breached == false
  end

  test "emits batch telemetry with bounded engine and path metadata" do
    start_supervised!(
      {NativeContextEngine, shard_count: 1, min_samples: 3, window_size: 3, confirm_slots: 1}
    )

    test_pid = self()
    handler_id = {__MODULE__, :batch_telemetry, make_ref()}

    :telemetry.attach(
      handler_id,
      [:serviceradar, :anomaly_detection, :batch, :completed],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    NativeContextEngine.evaluate_events_batch([
      sample("series-telemetry", 0, 10.0),
      sample("series-telemetry", 1, 11.0),
      sample("series-telemetry", 2, 12.0),
      sample("series-telemetry", 3, 30.0)
    ])

    assert_receive {:telemetry, [:serviceradar, :anomaly_detection, :batch, :completed],
                    measurements, metadata}

    assert metadata == %{engine: :native_context_engine, path: :events}
    assert measurements.count == 1
    assert measurements.input_samples == 4
    assert measurements.evaluations == 4
    assert measurements.emitted_events == 1
    assert measurements.duplicate_drops == 0
    assert measurements.failed_samples == 0
    assert is_integer(measurements.duration)
  end

  test "profiled batch evaluation reports phase timings" do
    start_supervised!(
      {NativeContextEngine, shard_count: 1, min_samples: 3, window_size: 3, confirm_slots: 1}
    )

    {results, profile} =
      NativeContextEngine.evaluate_events_batch_profiled([
        sample("series-profile", 0, 10.0),
        sample("series-profile", 1, 11.0),
        sample("series-profile", 2, 12.0),
        sample("series-profile", 3, 30.0)
      ])

    assert [{%{series_key: "series-profile"}, {:ok, %{anomalous: true}}}] = results
    assert profile.input_samples == 4
    assert profile.candidates == 4
    assert profile.duplicate_drops == 0
    assert profile.emitted_results == 1
    assert is_integer(profile.total_ns) and profile.total_ns > 0
    assert is_integer(profile.native_eval_ns) and profile.native_eval_ns >= 0
    assert is_integer(profile.shard_input_build_ns) and profile.shard_input_build_ns >= 0
  end

  test "serializes concurrent callers instead of returning shard lock errors" do
    start_supervised!(
      {NativeContextEngine, shard_count: 1, min_samples: 3, window_size: 3, confirm_slots: 1}
    )

    results =
      1..20
      |> Task.async_stream(
        fn batch ->
          NativeContextEngine.evaluate_events_batch([
            sample("series-#{batch}", batch * 10, 10.0),
            sample("series-#{batch}", batch * 10 + 1, 11.0),
            sample("series-#{batch}", batch * 10 + 2, 12.0)
          ])
        end,
        max_concurrency: 20,
        timeout: :infinity
      )
      |> Enum.flat_map(fn {:ok, result} -> result end)

    refute Enum.any?(results, fn
             {_sample, {:error, "runtime shard state lock unavailable"}} -> true
             {_sample, {:error, {:shard_exit, _reason}}} -> true
             _other -> false
           end)
  end

  test "redelivery does not mutate rolling state (continuation verdict is identical)" do
    # Snapshot-by-behavior: rolling_acc/window_tail live inside the Rust shard
    # and are not exported, so we assert that a redelivered batch leaves the
    # rolling state untouched by comparing the verdict of a fresh continuation
    # sample with and without an intervening redelivery. If redelivery had
    # re-folded the duplicates, the rolling stats (and thus the continuation
    # verdict) would differ.
    warmup = [
      sample("series-redeliver-state", 0, 10.0),
      sample("series-redeliver-state", 1, 11.0),
      sample("series-redeliver-state", 2, 12.0),
      sample("series-redeliver-state", 3, 30.0)
    ]

    # A clearly in-range sample so the continuation deterministically emits a
    # CLEAR state change (non-empty), making the parity comparison meaningful.
    continuation = [sample("series-redeliver-state", 4, 11.5)]

    # Baseline run: warm, then continuation, with NO redelivery in between.
    start_supervised!(
      {NativeContextEngine, shard_count: 1, min_samples: 3, window_size: 3, confirm_slots: 1}
    )

    assert [{_sample, {:ok, %{anomalous: true}}}] =
             NativeContextEngine.evaluate_events_batch(warmup)

    baseline_continuation = NativeContextEngine.evaluate_events_batch(continuation)
    stop_supervised!(NativeContextEngine)

    # Redelivery run: warm, redeliver the warmup (must all drop), then
    # continuation. The continuation verdict must match the baseline exactly.
    start_supervised!(
      {NativeContextEngine, shard_count: 1, min_samples: 3, window_size: 3, confirm_slots: 1}
    )

    assert [{_sample, {:ok, %{anomalous: true}}}] =
             NativeContextEngine.evaluate_events_batch(warmup)

    redelivered = NativeContextEngine.evaluate_events_batch(warmup)

    assert Enum.all?(redelivered, fn
             {_sample, {:drop, :duplicate_event}} -> true
             _other -> false
           end)

    redelivered_continuation = NativeContextEngine.evaluate_events_batch(continuation)

    # The continuation emits a CLEAR in both runs; redelivery must not have
    # perturbed the rolling state, so the verdicts are identical.
    assert [{_sample, {:ok, %{anomalous: false}}}] = baseline_continuation
    assert strip_results(redelivered_continuation) == strip_results(baseline_continuation)
  end

  test "checkpoint restore preserves native state and redelivery tokens" do
    {:ok, checkpoint_agent} = Agent.start_link(fn -> %{} end)

    opts = [
      shard_count: 1,
      min_samples: 3,
      window_size: 3,
      confirm_slots: 1,
      checkpoint_store: __MODULE__.AgentCheckpoint,
      checkpoint_opts: [agent: checkpoint_agent],
      checkpoint_flush_interval_ms: 0
    ]

    warmup = [
      sample("series-native-checkpoint", 0, 10.0),
      sample("series-native-checkpoint", 1, 11.0),
      sample("series-native-checkpoint", 2, 12.0),
      sample("series-native-checkpoint", 3, 30.0)
    ]

    start_supervised!({NativeContextEngine, opts})

    assert [{_sample, {:ok, %{anomalous: true}}}] =
             NativeContextEngine.evaluate_events_batch(warmup)

    stop_supervised!(NativeContextEngine)

    start_supervised!({NativeContextEngine, opts})

    assert Enum.all?(NativeContextEngine.evaluate_events_batch(warmup), fn
             {_sample, {:drop, :duplicate_event}} -> true
             _other -> false
           end)

    assert [{_sample, {:ok, clear}}] =
             NativeContextEngine.evaluate_events_batch([
               sample("series-native-checkpoint", 4, 11.5)
             ])

    assert clear.anomalous == false
    assert clear.breached == false
  end

  test "intra-batch duplicate event_id folds exactly once" do
    start_supervised!(
      {NativeContextEngine, shard_count: 1, min_samples: 3, window_size: 3, confirm_slots: 1}
    )

    duped = sample("series-intra-batch", 3, 30.0)

    samples = [
      sample("series-intra-batch", 0, 10.0),
      sample("series-intra-batch", 1, 11.0),
      sample("series-intra-batch", 2, 12.0),
      duped,
      # Exact same event_id as `duped`; must be dropped, not folded twice.
      duped
    ]

    results = NativeContextEngine.evaluate_events_batch(samples)

    # Exactly one in-batch duplicate is dropped.
    assert Enum.count(results, fn
             {_sample, {:drop, :duplicate_event}} -> true
             _other -> false
           end) == 1

    # The spike still opens exactly once.
    assert Enum.count(results, fn
             {_sample, {:ok, %{anomalous: true}}} -> true
             _other -> false
           end) == 1
  end

  test "eviction bounds the series table and a forgotten series re-warms cleanly" do
    # max_series 1 forces aggressive eviction; a fast prune interval lets the
    # periodic sweep run during the test.
    start_supervised!(
      {NativeContextEngine,
       shard_count: 1,
       min_samples: 3,
       window_size: 3,
       confirm_slots: 1,
       max_series: 1,
       eviction_budget: 100,
       event_prune_interval_ms: 20}
    )

    # Warm and breach several distinct series so they land in the LRU table.
    for series <- 1..5 do
      key = "series-evict-#{series}"

      NativeContextEngine.evaluate_events_batch([
        sample(key, 0, 10.0),
        sample(key, 1, 11.0),
        sample(key, 2, 12.0)
      ])
    end

    # Let the periodic prune run; the table must be bounded near max_series.
    wait_until(fn -> :ets.info(seen_table(), :size) <= 2 end)

    assert :ets.info(seen_table(), :size) <= 2

    # A forgotten series re-warms cleanly: feeding it again produces a fresh
    # OPEN on breach (state was dropped from the Rust shard on forget).
    rewarm = "series-evict-1"

    assert [{_sample, {:ok, %{anomalous: true}}}] =
             NativeContextEngine.evaluate_events_batch([
               sample(rewarm, 10, 10.0),
               sample(rewarm, 11, 11.0),
               sample(rewarm, 12, 12.0),
               sample(rewarm, 13, 30.0)
             ])
  end

  test "an active (open) series is not evicted while its anomaly is open" do
    start_supervised!(
      {NativeContextEngine,
       shard_count: 1,
       min_samples: 3,
       window_size: 3,
       confirm_slots: 1,
       max_series: 1,
       eviction_budget: 100,
       event_prune_interval_ms: 20}
    )

    open_key = "series-open-active"

    # Warm and open an anomaly that stays OPEN (no clearing sample yet).
    assert [{_sample, {:ok, %{anomalous: true}}}] =
             NativeContextEngine.evaluate_events_batch([
               sample(open_key, 0, 10.0),
               sample(open_key, 1, 11.0),
               sample(open_key, 2, 12.0),
               sample(open_key, 3, 30.0)
             ])

    # Churn many other series to drive heavy eviction pressure.
    for series <- 1..10 do
      key = "series-churn-#{series}"

      NativeContextEngine.evaluate_events_batch([
        sample(key, 0, 10.0),
        sample(key, 1, 11.0),
        sample(key, 2, 12.0)
      ])
    end

    # Give the periodic sweep time to run repeatedly.
    wait_until(fn -> :ets.info(seen_table(), :size) <= 2 end)

    # The active series must survive eviction so its anomaly can still clear.
    assert :ets.member(seen_table(), open_key)

    # And it does clear: feeding an in-range sample yields a CLEAR, proving the
    # Rust state for this series was never forgotten mid-anomaly.
    assert [{_sample, {:ok, clear}}] =
             NativeContextEngine.evaluate_events_batch([
               sample(open_key, 4, 11.5)
             ])

    assert clear.anomalous == false
    assert clear.breached == false
  end

  defp seen_table, do: ServiceRadar.Observability.AnomalyDetection.NativeContextEngine.SeenSeries

  defp strip_results(results) do
    Enum.map(results, fn {_sample, result} -> result end)
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("condition not met within timeout")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  defp sample(series_key, order, value) do
    %{
      series_key: series_key,
      event_id: "#{series_key}-#{order}",
      order_key: {order, "#{series_key}-#{order}"},
      value: value,
      observed_at_unix_nano: order,
      subject: "metrics.sysmon.cpu",
      metric_class: "sysmon.cpu"
    }
  end

  defp compact_sample(sample, index) do
    {index, sample.series_key, sample.event_id, sample.value, sample.observed_at_unix_nano,
     %{subject: sample.subject, metric_class: sample.metric_class}}
  end

  defmodule AgentCheckpoint do
    @moduledoc false
    def load(series_key, opts) do
      opts
      |> Keyword.fetch!(:agent)
      |> Agent.get(&Map.get(&1, series_key))
      |> case do
        nil -> {:ok, nil}
        checkpoint -> {:ok, checkpoint}
      end
    end

    def save(series_key, checkpoint, opts) do
      opts
      |> Keyword.fetch!(:agent)
      |> Agent.update(&Map.put(&1, series_key, checkpoint))

      :ok
    end
  end
end
