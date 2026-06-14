# Synthetic anomaly detection scale benchmark.
#
# Run from elixir/serviceradar_core:
#
#   MIX_ENV=test mix run --no-start bench/anomaly_detection_scale.exs
#
# Useful knobs:
#
#   ANOMALY_BENCH_MODE=owner|legacy_list|reasoner|reasoner_batch|reasoner_batch_shards|reasoner_state_batch_shards|reasoner_state_values_changes_shards|reasoner_state_value_tuples_changes_shards|native_engine_events|native_engine_compact_events|native_engine_prepared_shards|sharded_engine|sharded_engine_events|counter_normalizer
#   ANOMALY_BENCH_SERIES=50000
#   ANOMALY_BENCH_BASELINE=12
#   ANOMALY_BENCH_WINDOW=300
#   ANOMALY_BENCH_ANOMALY=3
#   ANOMALY_BENCH_ROLLUP_SAMPLES_PER_EVAL=1
#   ANOMALY_BENCH_CONCURRENCY=16
#   ANOMALY_BENCH_BATCH_SIZE=1000
#   ANOMALY_BENCH_PROFILE=true
#
# `owner` mode exercises the stateful ContextOwner + real CausalReasoner path.
# `legacy_list` mode exercises the old list-shaped NIF context. `reasoner`
# exercises the compact NIF state. `reasoner_batch*` modes amortize Rustler
# overhead across independent series while preserving per-series sample order.

defmodule ServiceRadar.Bench.AnomalyDetectionScale do
  @moduledoc false
  alias ServiceRadar.Observability.AnomalyDetection.ContextOwner
  alias ServiceRadar.Observability.AnomalyDetection.CounterNormalizer
  alias ServiceRadar.Observability.AnomalyDetection.NativeContextEngine
  alias ServiceRadar.Observability.AnomalyDetection.ShardedContextEngine
  alias ServiceRadar.Observability.CausalReasoner

  @detector_opts [
    min_samples: 10,
    window_size: 12,
    n_sigma: 3.0,
    confirm_slots: 3,
    suppress_until_warmed?: false,
    baseline_seed_opts: [enabled: false],
    checkpoint_store: __MODULE__.NoopCheckpoint,
    checkpoint_flush_interval_ms: 0,
    reasoner: CausalReasoner,
    name: nil
  ]

  def run do
    mode = System.get_env("ANOMALY_BENCH_MODE", "owner")
    series_count = env_int("ANOMALY_BENCH_SERIES", 5_000)
    baseline_count = env_int("ANOMALY_BENCH_BASELINE", 12)
    window_size = env_int("ANOMALY_BENCH_WINDOW", baseline_count)
    anomaly_count = env_int("ANOMALY_BENCH_ANOMALY", 3)
    rollup_samples_per_eval = env_int("ANOMALY_BENCH_ROLLUP_SAMPLES_PER_EVAL", 1)
    concurrency = env_int("ANOMALY_BENCH_CONCURRENCY", System.schedulers_online())
    batch_size = env_int("ANOMALY_BENCH_BATCH_SIZE", 1_000)
    profile? = env_bool("ANOMALY_BENCH_PROFILE", false)

    IO.puts("""
    ServiceRadar anomaly detection synthetic scale benchmark
    mode=#{mode}
    series=#{series_count}
    baseline_samples_per_series=#{baseline_count}
    window_size=#{window_size}
    anomaly_samples_per_series=#{anomaly_count}
    rollup_samples_per_eval=#{rollup_samples_per_eval}
    concurrency=#{concurrency}
    batch_size=#{batch_size}
    profile=#{profile?}
    reason_batch_scheduler=DirtyCpu
    """)

    :erlang.garbage_collect()
    memory_before = :erlang.memory(:total)
    started_at = System.monotonic_time()

    result =
      run_benchmark(
        mode,
        series_count,
        baseline_count,
        window_size,
        anomaly_count,
        rollup_samples_per_eval,
        concurrency,
        batch_size
      )

    elapsed_ns = System.monotonic_time() - started_at
    :erlang.garbage_collect()
    memory_after = :erlang.memory(:total)

    elapsed_s = System.convert_time_unit(elapsed_ns, :native, :microsecond) / 1_000_000
    evals_per_s = result.evaluations / max(elapsed_s, 0.001)
    raw_samples_per_s = result.raw_samples / max(elapsed_s, 0.001)
    series_per_s = series_count / max(elapsed_s, 0.001)
    memory_delta_mb = (memory_after - memory_before) / 1_048_576

    IO.puts("""
    Results
    elapsed_seconds=#{Float.round(elapsed_s, 3)}
    raw_samples=#{result.raw_samples}
    raw_samples_per_second=#{round(raw_samples_per_s)}
    evaluations=#{result.evaluations}
    evaluations_per_second=#{round(evals_per_s)}
    series_per_second=#{round(series_per_s)}
    confirmed_anomalies=#{result.confirmed}
    failed_series=#{result.failed}
    emitted_events=#{Map.get(result, :emitted, 0)}
    duplicate_drops=#{Map.get(result, :duplicate_drops, 0)}
    memory_delta_mb=#{Float.round(memory_delta_mb, 2)}
    """)

    print_profile(result, result.evaluations)
  end

  defp run_benchmark(
         "counter_normalizer",
         series_count,
         baseline_count,
         _window_size,
         anomaly_count,
         rollup_samples_per_eval,
         concurrency,
         _batch_size
       ) do
    table =
      :ets.new(:counter_normalizer_bench, [
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    sample_count = baseline_count + anomaly_count
    raw_count = sample_count * rollup_samples_per_eval
    shard_count = min(concurrency, series_count)

    try do
      1..shard_count
      |> Task.async_stream(
        fn shard ->
          shard
          |> Range.new(series_count, shard_count)
          |> Enum.reduce(%{evaluations: 0, raw_samples: 0, confirmed: 0, failed: 0}, fn index,
                                                                                        acc ->
            metrics = run_counter_normalizer_series(index, raw_count, table)
            merge_metrics(acc, metrics)
          end)
        end,
        max_concurrency: shard_count,
        timeout: :infinity,
        ordered: false
      )
      |> reduce_task_results()
    after
      :ets.delete(table)
    end
  end

  defp run_benchmark(
         "sharded_engine",
         series_count,
         baseline_count,
         window_size,
         anomaly_count,
         rollup_samples_per_eval,
         concurrency,
         _batch_size
       ) do
    ensure_sharded_engine!(concurrency, window_size)

    slot_count = baseline_count + anomaly_count

    Enum.reduce(
      1..slot_count,
      %{evaluations: 0, raw_samples: 0, confirmed: 0, failed: 0},
      fn slot, metrics ->
        samples =
          Enum.map(1..series_count, fn index ->
            dataset = dataset(index)
            value = slot_value(dataset, slot, baseline_count, rollup_samples_per_eval)
            sample(dataset, "slot-#{slot}", slot, value)
          end)

        results = ShardedContextEngine.evaluate_batch(samples)

        Enum.reduce(results, metrics, fn
          {:ok, verdict}, metrics ->
            %{
              metrics
              | evaluations: metrics.evaluations + 1,
                raw_samples: metrics.raw_samples + rollup_samples_per_eval,
                confirmed: metrics.confirmed + confirmed?(verdict)
            }

          {:drop, _reason}, metrics ->
            %{metrics | failed: metrics.failed + 1}

          {:error, reason}, metrics ->
            IO.puts("sharded engine item failed: #{inspect(reason)}")
            %{metrics | failed: metrics.failed + 1}
        end)
      end
    )
  end

  defp run_benchmark(
         "sharded_engine_events",
         series_count,
         baseline_count,
         window_size,
         anomaly_count,
         rollup_samples_per_eval,
         concurrency,
         _batch_size
       ) do
    ensure_sharded_engine!(concurrency, window_size)

    slot_count = baseline_count + anomaly_count

    Enum.reduce(
      1..slot_count,
      %{evaluations: 0, raw_samples: 0, confirmed: 0, failed: 0},
      fn slot, metrics ->
        samples =
          Enum.map(1..series_count, fn index ->
            dataset = dataset(index)
            value = slot_value(dataset, slot, baseline_count, rollup_samples_per_eval)
            sample(dataset, "slot-#{slot}", slot, value)
          end)

        results = ShardedContextEngine.evaluate_events_batch(samples)

        results
        |> Enum.reduce(%{metrics | evaluations: metrics.evaluations + series_count}, fn
          {_sample, {:ok, verdict}}, metrics ->
            increment(
              %{
                metrics
                | raw_samples: metrics.raw_samples + rollup_samples_per_eval,
                  confirmed: metrics.confirmed + confirmed?(verdict)
              },
              :emitted
            )

          {_sample, {:drop, :duplicate_event}}, metrics ->
            increment(metrics, :duplicate_drops)

          {_sample, {:drop, _reason}}, metrics ->
            %{metrics | failed: metrics.failed + 1}

          {_sample, {:error, reason}}, metrics ->
            IO.puts("sharded event engine item failed: #{inspect(reason)}")
            %{metrics | failed: metrics.failed + 1}
        end)
        |> Map.update!(
          :raw_samples,
          &(&1 + (series_count - length(results)) * rollup_samples_per_eval)
        )
      end
    )
  end

  defp run_benchmark(
         "native_engine_events",
         series_count,
         baseline_count,
         window_size,
         anomaly_count,
         rollup_samples_per_eval,
         concurrency,
         _batch_size
       ) do
    ensure_native_engine!(concurrency, window_size)

    slot_count = baseline_count + anomaly_count

    Enum.reduce(
      1..slot_count,
      %{evaluations: 0, raw_samples: 0, confirmed: 0, failed: 0, profile: %{}},
      fn slot, metrics ->
        samples =
          Enum.map(1..series_count, fn index ->
            dataset = dataset(index)
            value = slot_value(dataset, slot, baseline_count, rollup_samples_per_eval)
            sample(dataset, "slot-#{slot}", slot, value)
          end)

        {results, profile} =
          if env_bool("ANOMALY_BENCH_PROFILE", false) do
            NativeContextEngine.evaluate_events_batch_profiled(samples)
          else
            {NativeContextEngine.evaluate_events_batch(samples), %{}}
          end

        results
        |> Enum.reduce(
          %{
            metrics
            | evaluations: metrics.evaluations + series_count,
              profile: merge_profile(metrics.profile, profile)
          },
          fn {_sample, result}, metrics ->
            case result do
              {:ok, verdict} ->
                metrics
                |> Map.update!(:raw_samples, &(&1 + rollup_samples_per_eval))
                |> Map.update!(:confirmed, &(&1 + confirmed?(verdict)))
                |> increment(:emitted)

              {:drop, :duplicate_event} ->
                increment(metrics, :duplicate_drops)

              {:drop, _reason} ->
                %{metrics | failed: metrics.failed + 1}

              {:error, reason} ->
                IO.puts("native event engine item failed: #{inspect(reason)}")
                %{metrics | failed: metrics.failed + 1}
            end
          end
        )
        |> Map.update!(
          :raw_samples,
          &(&1 + (series_count - length(results)) * rollup_samples_per_eval)
        )
      end
    )
  end

  defp run_benchmark(
         "native_engine_compact_events",
         series_count,
         baseline_count,
         window_size,
         anomaly_count,
         rollup_samples_per_eval,
         concurrency,
         _batch_size
       ) do
    ensure_native_engine!(concurrency, window_size)

    slot_count = baseline_count + anomaly_count

    Enum.reduce(
      1..slot_count,
      %{evaluations: 0, raw_samples: 0, confirmed: 0, failed: 0, profile: %{}},
      fn slot, metrics ->
        samples =
          Enum.map(1..series_count, fn index ->
            dataset = dataset(index)
            value = slot_value(dataset, slot, baseline_count, rollup_samples_per_eval)
            compact_event_sample(dataset, index - 1, "slot-#{slot}", slot, value)
          end)

        {results, profile} =
          if env_bool("ANOMALY_BENCH_PROFILE", false) do
            NativeContextEngine.evaluate_compact_events_batch_profiled(samples)
          else
            {NativeContextEngine.evaluate_compact_events_batch(samples), %{}}
          end

        results
        |> Enum.reduce(
          %{
            metrics
            | evaluations: metrics.evaluations + series_count,
              profile: merge_profile(metrics.profile, profile)
          },
          fn {_sample, result}, metrics ->
            case result do
              {:ok, verdict} ->
                metrics
                |> Map.update!(:raw_samples, &(&1 + rollup_samples_per_eval))
                |> Map.update!(:confirmed, &(&1 + confirmed?(verdict)))
                |> increment(:emitted)

              {:drop, :duplicate_event} ->
                increment(metrics, :duplicate_drops)

              {:drop, _reason} ->
                %{metrics | failed: metrics.failed + 1}

              {:error, reason} ->
                IO.puts("native compact event engine item failed: #{inspect(reason)}")
                %{metrics | failed: metrics.failed + 1}
            end
          end
        )
        |> Map.update!(
          :raw_samples,
          &(&1 + (series_count - length(results)) * rollup_samples_per_eval)
        )
      end
    )
  end

  defp run_benchmark(
         "native_engine_prepared_shards",
         series_count,
         baseline_count,
         window_size,
         anomaly_count,
         rollup_samples_per_eval,
         concurrency,
         _batch_size
       ) do
    shard_count = min(concurrency, series_count)
    ensure_native_engine!(shard_count, window_size)

    slot_count = baseline_count + anomaly_count
    context = reasoner_context(window_size)

    Enum.reduce(
      1..slot_count,
      %{evaluations: 0, raw_samples: 0, confirmed: 0, failed: 0},
      fn slot, metrics ->
        results =
          series_count
          |> prepared_shard_batches(
            shard_count,
            slot,
            baseline_count,
            rollup_samples_per_eval,
            context
          )
          |> NativeContextEngine.evaluate_prepared_shard_batches()

        results
        |> Enum.reduce(%{metrics | evaluations: metrics.evaluations + series_count}, fn
          {_index, {:ok, verdict}}, metrics ->
            metrics
            |> Map.update!(:raw_samples, &(&1 + rollup_samples_per_eval))
            |> Map.update!(:confirmed, &(&1 + confirmed?(verdict)))
            |> increment(:emitted)

          {_index, {:error, reason}}, metrics ->
            IO.puts("native prepared shard item failed: #{inspect(reason)}")
            %{metrics | failed: metrics.failed + 1}
        end)
        |> Map.update!(
          :raw_samples,
          &(&1 + (series_count - length(results)) * rollup_samples_per_eval)
        )
      end
    )
  end

  defp run_benchmark(
         "reasoner_batch",
         series_count,
         baseline_count,
         window_size,
         anomaly_count,
         rollup_samples_per_eval,
         _concurrency,
         batch_size
       ) do
    run_reasoner_batch_shard(
      1..series_count,
      baseline_count,
      window_size,
      anomaly_count,
      rollup_samples_per_eval,
      batch_size
    )
  end

  defp run_benchmark(
         "reasoner_batch_shards",
         series_count,
         baseline_count,
         window_size,
         anomaly_count,
         rollup_samples_per_eval,
         concurrency,
         batch_size
       ) do
    shard_count = min(concurrency, series_count)

    1..shard_count
    |> Task.async_stream(
      fn shard ->
        shard
        |> Range.new(series_count, shard_count)
        |> run_reasoner_batch_shard(
          baseline_count,
          window_size,
          anomaly_count,
          rollup_samples_per_eval,
          batch_size
        )
      end,
      max_concurrency: shard_count,
      timeout: :infinity,
      ordered: false
    )
    |> reduce_task_results()
  end

  defp run_benchmark(
         "reasoner_state_batch_shards",
         series_count,
         baseline_count,
         window_size,
         anomaly_count,
         rollup_samples_per_eval,
         concurrency,
         batch_size
       ) do
    shard_count = min(concurrency, series_count)

    1..shard_count
    |> Task.async_stream(
      fn shard ->
        shard
        |> Range.new(series_count, shard_count)
        |> run_reasoner_state_batch_shard(
          baseline_count,
          window_size,
          anomaly_count,
          rollup_samples_per_eval,
          batch_size
        )
      end,
      max_concurrency: shard_count,
      timeout: :infinity,
      ordered: false
    )
    |> reduce_task_results()
  end

  defp run_benchmark(
         "reasoner_state_values_changes_shards",
         series_count,
         baseline_count,
         window_size,
         anomaly_count,
         rollup_samples_per_eval,
         concurrency,
         batch_size
       ) do
    shard_count = min(concurrency, series_count)

    1..shard_count
    |> Task.async_stream(
      fn shard ->
        shard
        |> Range.new(series_count, shard_count)
        |> run_reasoner_state_values_change_shard(
          baseline_count,
          window_size,
          anomaly_count,
          rollup_samples_per_eval,
          batch_size
        )
      end,
      max_concurrency: shard_count,
      timeout: :infinity,
      ordered: false
    )
    |> reduce_task_results()
  end

  defp run_benchmark(
         "reasoner_state_value_tuples_changes_shards",
         series_count,
         baseline_count,
         window_size,
         anomaly_count,
         rollup_samples_per_eval,
         concurrency,
         batch_size
       ) do
    shard_count = min(concurrency, series_count)

    1..shard_count
    |> Task.async_stream(
      fn shard ->
        shard
        |> Range.new(series_count, shard_count)
        |> run_reasoner_state_value_tuple_change_shard(
          baseline_count,
          window_size,
          anomaly_count,
          rollup_samples_per_eval,
          batch_size
        )
      end,
      max_concurrency: shard_count,
      timeout: :infinity,
      ordered: false
    )
    |> reduce_task_results()
  end

  defp run_benchmark(
         mode,
         series_count,
         baseline_count,
         window_size,
         anomaly_count,
         rollup_samples_per_eval,
         concurrency,
         _batch_size
       ) do
    1..series_count
    |> Task.async_stream(
      &run_series(
        &1,
        mode,
        baseline_count,
        window_size,
        anomaly_count,
        rollup_samples_per_eval
      ),
      max_concurrency: concurrency,
      timeout: :infinity,
      ordered: false
    )
    |> reduce_task_results()
  end

  defp run_reasoner_batch_shard(
         series_indexes,
         baseline_count,
         window_size,
         anomaly_count,
         rollup_samples_per_eval,
         batch_size
       ) do
    indexes = Enum.to_list(series_indexes)
    slot_count = baseline_count + anomaly_count
    contexts = Map.new(indexes, &{&1, reasoner_context(window_size)})

    {metrics, _contexts} =
      Enum.reduce(
        1..slot_count,
        {%{evaluations: 0, raw_samples: 0, confirmed: 0, failed: 0}, contexts},
        fn slot, {metrics, contexts} ->
          indexes
          |> Enum.chunk_every(batch_size)
          |> Enum.reduce({metrics, contexts}, fn chunk, {metrics, contexts} ->
            inputs =
              Enum.map(chunk, fn index ->
                dataset = dataset(index)
                value = slot_value(dataset, slot, baseline_count, rollup_samples_per_eval)

                {
                  Map.fetch!(contexts, index),
                  %{value: value, observed_at_unix_nano: slot}
                }
              end)

            results = CausalReasoner.reason_batch(inputs)

            chunk
            |> Enum.zip(results)
            |> Enum.reduce({metrics, contexts}, fn
              {index, {:ok, verdict}}, {metrics, contexts} ->
                dataset = dataset(index)
                value = slot_value(dataset, slot, baseline_count, rollup_samples_per_eval)
                context = Map.fetch!(contexts, index)

                {
                  %{
                    metrics
                    | evaluations: metrics.evaluations + 1,
                      raw_samples: metrics.raw_samples + rollup_samples_per_eval,
                      confirmed: metrics.confirmed + confirmed?(verdict)
                  },
                  Map.put(contexts, index, fold_context(context, value, verdict))
                }

              {_index, {:error, reason}}, {metrics, contexts} ->
                IO.puts("reason_batch item failed: #{inspect(reason)}")
                {%{metrics | failed: metrics.failed + 1}, contexts}
            end)
          end)
        end
      )

    metrics
  end

  defp run_reasoner_state_batch_shard(
         series_indexes,
         baseline_count,
         window_size,
         anomaly_count,
         rollup_samples_per_eval,
         batch_size
       ) do
    indexes = Enum.to_list(series_indexes)
    slot_count = baseline_count + anomaly_count
    context = reasoner_context(window_size)
    shard_state = CausalReasoner.new_shard_state()

    Enum.reduce(
      1..slot_count,
      %{evaluations: 0, raw_samples: 0, confirmed: 0, failed: 0},
      fn slot, metrics ->
        indexes
        |> Enum.chunk_every(batch_size)
        |> Enum.reduce(metrics, fn chunk, metrics ->
          inputs =
            Enum.map(chunk, fn index ->
              dataset = dataset(index)
              value = slot_value(dataset, slot, baseline_count, rollup_samples_per_eval)

              %{
                series_key: dataset.series_key,
                context: context,
                sample: %{value: value, observed_at_unix_nano: slot}
              }
            end)

          results = CausalReasoner.reason_state_batch_events(shard_state, inputs)

          Enum.reduce(results, metrics, fn
            {:ok, verdict}, metrics ->
              %{
                metrics
                | evaluations: metrics.evaluations + 1,
                  raw_samples: metrics.raw_samples + rollup_samples_per_eval,
                  confirmed: metrics.confirmed + confirmed?(verdict)
              }

            {:error, reason}, metrics ->
              IO.puts("reason_state_batch item failed: #{inspect(reason)}")
              %{metrics | failed: metrics.failed + 1}
          end)
        end)
      end
    )
  end

  defp reduce_task_results(stream) do
    Enum.reduce(stream, %{evaluations: 0, raw_samples: 0, confirmed: 0, failed: 0}, fn
      {:ok, metrics}, acc ->
        merge_metrics(acc, metrics)

      {:exit, reason}, acc ->
        IO.puts("series task failed: #{inspect(reason)}")
        %{acc | failed: acc.failed + 1}
    end)
  end

  defp run_reasoner_state_values_change_shard(
         series_indexes,
         baseline_count,
         window_size,
         anomaly_count,
         rollup_samples_per_eval,
         batch_size
       ) do
    indexes = Enum.to_list(series_indexes)
    slot_count = baseline_count + anomaly_count
    context = reasoner_context(window_size)
    shard_state = CausalReasoner.new_shard_state()

    Enum.reduce(
      1..slot_count,
      %{evaluations: 0, raw_samples: 0, confirmed: 0, failed: 0},
      fn slot, metrics ->
        indexes
        |> Enum.chunk_every(batch_size)
        |> Enum.reduce(metrics, fn chunk, metrics ->
          inputs =
            Enum.map(chunk, fn index ->
              dataset = dataset(index)
              value = slot_value(dataset, slot, baseline_count, rollup_samples_per_eval)

              %{
                index: index,
                series_key: dataset.series_key,
                context: if(slot == 1, do: context),
                value: value,
                observed_at_unix_nano: slot
              }
            end)

          results = CausalReasoner.reason_state_values_changes(shard_state, inputs)

          results
          |> Enum.reduce(%{metrics | evaluations: metrics.evaluations + length(chunk)}, fn
            {_index, {:ok, verdict}}, metrics ->
              %{
                metrics
                | raw_samples: metrics.raw_samples + rollup_samples_per_eval,
                  confirmed: metrics.confirmed + confirmed?(verdict)
              }

            {_index, {:error, reason}}, metrics ->
              IO.puts("reason_state_values item failed: #{inspect(reason)}")
              %{metrics | failed: metrics.failed + 1}
          end)
          |> Map.update!(
            :raw_samples,
            &(&1 + (length(chunk) - length(results)) * rollup_samples_per_eval)
          )
        end)
      end
    )
  end

  defp run_reasoner_state_value_tuple_change_shard(
         series_indexes,
         baseline_count,
         window_size,
         anomaly_count,
         rollup_samples_per_eval,
         batch_size
       ) do
    indexes = Enum.to_list(series_indexes)
    slot_count = baseline_count + anomaly_count
    context = reasoner_context(window_size)
    shard_state = CausalReasoner.new_shard_state()

    Enum.reduce(
      1..slot_count,
      %{evaluations: 0, raw_samples: 0, confirmed: 0, failed: 0},
      fn slot, metrics ->
        indexes
        |> Enum.chunk_every(batch_size)
        |> Enum.reduce(metrics, fn chunk, metrics ->
          inputs =
            Enum.map(chunk, fn index ->
              dataset = dataset(index)
              value = slot_value(dataset, slot, baseline_count, rollup_samples_per_eval)

              {index, dataset.series_key, if(slot == 1, do: context), value, slot}
            end)

          results = CausalReasoner.reason_state_value_tuples_changes(shard_state, inputs)

          results
          |> Enum.reduce(%{metrics | evaluations: metrics.evaluations + length(chunk)}, fn
            {_index, {:ok, verdict}}, metrics ->
              %{
                metrics
                | raw_samples: metrics.raw_samples + rollup_samples_per_eval,
                  confirmed: metrics.confirmed + confirmed?(verdict)
              }

            {_index, {:error, reason}}, metrics ->
              IO.puts("reason_state_value_tuples item failed: #{inspect(reason)}")
              %{metrics | failed: metrics.failed + 1}
          end)
          |> Map.update!(
            :raw_samples,
            &(&1 + (length(chunk) - length(results)) * rollup_samples_per_eval)
          )
        end)
      end
    )
  end

  defp merge_metrics(acc, metrics) do
    %{
      evaluations: acc.evaluations + metrics.evaluations,
      raw_samples: acc.raw_samples + metrics.raw_samples,
      confirmed: acc.confirmed + metrics.confirmed,
      failed: acc.failed + Map.get(metrics, :failed, 0),
      emitted: Map.get(acc, :emitted, 0) + Map.get(metrics, :emitted, 0),
      duplicate_drops: Map.get(acc, :duplicate_drops, 0) + Map.get(metrics, :duplicate_drops, 0),
      profile: merge_profile(Map.get(acc, :profile, %{}), Map.get(metrics, :profile, %{}))
    }
  end

  defp merge_profile(left, right) when map_size(right) == 0, do: left
  defp merge_profile(left, right) when map_size(left) == 0, do: right

  defp merge_profile(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_number(left_value) and is_number(right_value) do
        left_value + right_value
      else
        right_value
      end
    end)
  end

  defp increment(metrics, key) do
    Map.update(metrics, key, 1, &(&1 + 1))
  end

  defp print_profile(%{profile: profile}, evaluations) when map_size(profile) > 0 do
    total_ns = Map.get(profile, :total_ns, 0)

    IO.puts("Profile")

    Enum.each(
      [
        :batch_prepare_ns,
        :dedupe_ns,
        :missing_split_ns,
        :sample_lookup_ns,
        :shard_input_build_ns,
        :native_eval_ns,
        :eviction_ns,
        :result_indexing_ns,
        :mark_seen_ns,
        :prune_seen_ns,
        :result_reassociation_ns,
        :total_ns
      ],
      fn key ->
        value = Map.get(profile, key, 0)
        pct = if total_ns > 0, do: value / total_ns * 100, else: 0.0
        ns_per_eval = value / max(evaluations, 1)

        IO.puts(
          "#{key}=#{value} ms=#{Float.round(value / 1_000_000, 3)} pct=#{Float.round(pct, 2)} ns_per_eval=#{Float.round(ns_per_eval, 1)}"
        )
      end
    )

    IO.puts("""
    Profile counters
    input_samples=#{Map.get(profile, :input_samples, 0)}
    candidates=#{Map.get(profile, :candidates, 0)}
    missing_samples=#{Map.get(profile, :missing_samples, 0)}
    duplicate_drops=#{Map.get(profile, :duplicate_drops, 0)}
    emitted_results=#{Map.get(profile, :emitted_results, 0)}
    native_results=#{Map.get(profile, :native_results, 0)}
    """)
  end

  defp print_profile(_result, _evaluations), do: :ok

  defp run_series(
         index,
         "owner",
         baseline_count,
         window_size,
         anomaly_count,
         rollup_samples_per_eval
       ) do
    dataset = dataset(index)
    raw_samples = (baseline_count + anomaly_count) * rollup_samples_per_eval

    {:ok, owner} =
      @detector_opts
      |> Keyword.put(:series_key, dataset.series_key)
      |> Keyword.put(:window_size, window_size)
      |> ContextOwner.start_link()

    try do
      {evaluations, confirmed} =
        dataset
        |> samples(baseline_count, anomaly_count, rollup_samples_per_eval)
        |> Enum.reduce({0, 0}, fn {event_id, order, value}, {evaluations, confirmed} ->
          {:ok, verdict} = ContextOwner.evaluate(owner, sample(dataset, event_id, order, value))
          {evaluations + 1, confirmed + confirmed?(verdict)}
        end)

      %{evaluations: evaluations, raw_samples: raw_samples, confirmed: confirmed}
    after
      stop_owner(owner)
    end
  end

  defp run_series(
         index,
         "legacy_list",
         baseline_count,
         window_size,
         anomaly_count,
         rollup_samples_per_eval
       ) do
    dataset = dataset(index)
    raw_samples = (baseline_count + anomaly_count) * rollup_samples_per_eval

    context = %{
      baseline: [],
      min_samples: 10,
      window_size: window_size,
      n_sigma: 3.0,
      confirm_slots: 3,
      consecutive_anomalous: 0
    }

    {evaluations, confirmed, _context} =
      dataset
      |> samples(baseline_count, anomaly_count, rollup_samples_per_eval)
      |> Enum.reduce({0, 0, context}, fn {_event_id, order, value},
                                         {evaluations, confirmed, context} ->
        {:ok, verdict} =
          CausalReasoner.reason(context, %{value: value, observed_at_unix_nano: order})

        {evaluations + 1, confirmed + confirmed?(verdict),
         fold_legacy_context(context, value, verdict)}
      end)

    %{evaluations: evaluations, raw_samples: raw_samples, confirmed: confirmed}
  end

  defp run_series(
         index,
         "reasoner",
         baseline_count,
         window_size,
         anomaly_count,
         rollup_samples_per_eval
       ) do
    dataset = dataset(index)
    raw_samples = (baseline_count + anomaly_count) * rollup_samples_per_eval

    context = reasoner_context(window_size)

    {evaluations, confirmed, _context} =
      dataset
      |> samples(baseline_count, anomaly_count, rollup_samples_per_eval)
      |> Enum.reduce({0, 0, context}, fn {_event_id, order, value},
                                         {evaluations, confirmed, context} ->
        {:ok, verdict} =
          CausalReasoner.reason(context, %{value: value, observed_at_unix_nano: order})

        {evaluations + 1, confirmed + confirmed?(verdict), fold_context(context, value, verdict)}
      end)

    %{evaluations: evaluations, raw_samples: raw_samples, confirmed: confirmed}
  end

  defp run_series(_index, mode, _baseline_count, _window_size, _anomaly_count, _rollup_samples) do
    raise "unsupported ANOMALY_BENCH_MODE=#{inspect(mode)}; expected owner, legacy_list, reasoner, reasoner_batch, reasoner_batch_shards, reasoner_state_batch_shards, reasoner_state_values_changes_shards, reasoner_state_value_tuples_changes_shards, native_engine_events, native_engine_compact_events, native_engine_prepared_shards, sharded_engine, sharded_engine_events, or counter_normalizer"
  end

  defp run_counter_normalizer_series(index, raw_count, table) do
    series_key = "bench:counter:agent-#{index}:ifHCInOctets"

    emitted =
      Enum.reduce(1..raw_count, 0, fn order, emitted ->
        value = 1_000_000_000_000 + order * 1_000
        timestamp = order * 1_000_000_000

        case CounterNormalizer.normalize_sample(
               counter_sample(series_key, value, timestamp),
               table
             ) do
          {:ok, _sample} -> emitted + 1
          {:drop, _reason} -> emitted
        end
      end)

    %{evaluations: emitted, raw_samples: raw_count, confirmed: 0, failed: 0}
  end

  defp dataset(index) do
    case rem(index, 4) do
      0 ->
        %{
          series_key: "bench:sysmon:cpu:agent-#{index}:all",
          subject: "metrics.sysmon.cpu",
          metric_class: "sysmon.cpu",
          normal_base: 40.0,
          normal_step: 0.2,
          anomaly_base: 88.0
        }

      1 ->
        %{
          series_key: "bench:sysmon:memory:agent-#{index}",
          subject: "metrics.sysmon.memory",
          metric_class: "sysmon.memory",
          normal_base: 55.0,
          normal_step: 0.2,
          anomaly_base: 93.0
        }

      2 ->
        %{
          series_key: "bench:sysmon:disk:agent-#{index}:/var",
          subject: "metrics.sysmon.disk",
          metric_class: "sysmon.disk",
          normal_base: 62.0,
          normal_step: 0.2,
          anomaly_base: 88.0
        }

      _ ->
        %{
          series_key: "bench:flow:agent-#{index}:10.0.0.1:10.0.0.2:6",
          subject: "flows.raw.netflow",
          metric_class: "flow",
          normal_base: 1_000.0,
          normal_step: 20.0,
          anomaly_base: 5_000.0
        }
    end
  end

  defp samples(dataset, baseline_count, anomaly_count, rollup_samples_per_eval) do
    normal =
      Enum.map(1..baseline_count, fn order ->
        {"normal-#{order}", order, normal_rollup_value(dataset, order, rollup_samples_per_eval)}
      end)

    anomalies =
      Enum.map(1..anomaly_count, fn offset ->
        order = baseline_count + offset

        {"anomaly-#{order}", order,
         anomaly_rollup_value(dataset, offset, rollup_samples_per_eval)}
      end)

    normal ++ anomalies
  end

  defp slot_value(dataset, slot, baseline_count, rollup_samples_per_eval) do
    if slot <= baseline_count do
      normal_rollup_value(dataset, slot, rollup_samples_per_eval)
    else
      anomaly_rollup_value(dataset, slot - baseline_count, rollup_samples_per_eval)
    end
  end

  defp reasoner_context(window_size) do
    %{
      baseline: [],
      window_tail: [],
      rolling_acc: %{count: 0, mean: 0.0, m2: 0.0},
      min_samples: 10,
      window_size: window_size,
      n_sigma: 3.0,
      confirm_slots: 3,
      consecutive_anomalous: 0
    }
  end

  defp ensure_sharded_engine!(shard_count, window_size) do
    Application.put_env(:serviceradar_core, :anomaly_detection_shard_count, shard_count)

    case Process.whereis(ShardedContextEngine) do
      nil ->
        {:ok, _pid} =
          ShardedContextEngine.start_link(
            shard_count: shard_count,
            min_samples: 10,
            window_size: window_size,
            n_sigma: 3.0,
            confirm_slots: 3
          )

        :ok

      _pid ->
        :ok
    end
  end

  defp ensure_native_engine!(shard_count, window_size) do
    Application.put_env(:serviceradar_core, :anomaly_detection_shard_count, shard_count)

    case Process.whereis(NativeContextEngine) do
      nil ->
        {:ok, _pid} =
          NativeContextEngine.start_link(
            shard_count: shard_count,
            min_samples: 10,
            window_size: window_size,
            n_sigma: 3.0,
            confirm_slots: 3
          )

        :ok

      _pid ->
        :ok
    end
  end

  defp normal_rollup_value(dataset, order, rollup_samples_per_eval) do
    order
    |> raw_sample_orders(rollup_samples_per_eval)
    |> Enum.map(&normal_value(dataset, &1))
    |> Enum.max()
  end

  defp anomaly_rollup_value(dataset, offset, rollup_samples_per_eval) do
    1..rollup_samples_per_eval
    |> Enum.map(&(dataset.anomaly_base + offset + &1 / 1_000))
    |> Enum.max()
  end

  defp raw_sample_orders(order, rollup_samples_per_eval) do
    first = (order - 1) * rollup_samples_per_eval + 1
    last = first + rollup_samples_per_eval - 1
    first..last
  end

  defp normal_value(dataset, order) do
    dataset.normal_base + dataset.normal_step * :math.sin(order)
  end

  defp sample(dataset, event_id, order, value) do
    %{
      series_key: dataset.series_key,
      event_id: "#{dataset.series_key}:#{event_id}",
      order_key: {order, event_id},
      value: value,
      observed_at_unix_nano: order,
      subject: dataset.subject,
      metric_class: dataset.metric_class,
      metadata: %{}
    }
  end

  defp compact_event_sample(dataset, index, event_id, order, value) do
    {index, dataset.series_key, "#{dataset.series_key}:#{event_id}", value, order,
     %{subject: dataset.subject, metric_class: dataset.metric_class}}
  end

  defp prepared_shard_batches(
         series_count,
         shard_count,
         slot,
         baseline_count,
         rollup_samples_per_eval,
         context
       ) do
    groups =
      Enum.reduce(1..series_count, :erlang.make_tuple(shard_count, []), fn index, groups ->
        dataset = dataset(index)
        value = slot_value(dataset, slot, baseline_count, rollup_samples_per_eval)
        shard_index = :erlang.phash2(dataset.series_key, shard_count)

        input =
          {index - 1, dataset.series_key, if(slot == 1, do: context), value, slot}

        put_elem(groups, shard_index, [input | elem(groups, shard_index)])
      end)

    0..(shard_count - 1)
    |> Enum.map(fn shard_index -> {shard_index, Enum.reverse(elem(groups, shard_index))} end)
    |> Enum.reject(fn {_shard_index, inputs} -> inputs == [] end)
  end

  defp counter_sample(series_key, value, timestamp) do
    %{
      series_key: series_key,
      event_id: "#{series_key}:#{timestamp}",
      order_key: {timestamp, "#{series_key}:#{timestamp}"},
      value: value,
      observed_at_unix_nano: timestamp,
      subject: "otel.metrics.raw",
      metric_class: "otel.metric_point",
      metadata: %{
        metric_type: "sum",
        temporality: "cumulative",
        is_monotonic: true,
        unit: "By",
        start_time_unix_nano: 1
      }
    }
  end

  defp fold_context(context, _value, verdict) do
    next_window_tail = Map.get(verdict, :next_window_tail, context.window_tail || [])
    next_rolling_acc = Map.get(verdict, :next_rolling_acc, context.rolling_acc)

    %{
      context
      | baseline: [],
        window_tail: next_window_tail,
        rolling_acc: next_rolling_acc,
        consecutive_anomalous: Map.get(verdict, :next_consecutive_anomalous, 0)
    }
  end

  defp fold_legacy_context(context, value, verdict) do
    baseline =
      if Map.get(verdict, :include_in_baseline, true) do
        context.baseline
        |> Kernel.++([value])
        |> Enum.take(-context.window_size)
      else
        context.baseline
      end

    %{
      context
      | baseline: baseline,
        consecutive_anomalous: Map.get(verdict, :next_consecutive_anomalous, 0)
    }
  end

  defp confirmed?(%{anomalous: true}), do: 1
  defp confirmed?(_verdict), do: 0

  defp stop_owner(owner) do
    if Process.alive?(owner), do: GenServer.stop(owner)
  catch
    :exit, _reason -> :ok
  end

  defp env_int(name, default) do
    case System.get_env(name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> default
        end
    end
  end

  defp env_bool(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> String.downcase(String.trim(value)) in ["1", "true", "yes", "on"]
    end
  end

  defmodule NoopCheckpoint do
    @moduledoc false

    def load(_series_key, _opts), do: {:ok, nil}
    def save(_series_key, _checkpoint, _opts), do: :ok
  end
end

ServiceRadar.Bench.AnomalyDetectionScale.run()
