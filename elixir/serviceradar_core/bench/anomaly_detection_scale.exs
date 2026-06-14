# Synthetic anomaly detection scale benchmark.
#
# Run from elixir/serviceradar_core:
#
#   MIX_ENV=test mix run --no-start bench/anomaly_detection_scale.exs
#
# Useful knobs:
#
#   ANOMALY_BENCH_MODE=owner|legacy_list|reasoner|reasoner_batch|reasoner_batch_shards|reasoner_state_batch_shards|reasoner_state_values_changes_shards|reasoner_state_value_tuples_changes_shards|native_engine_events|native_engine_compact_events|native_engine_prepared_shards|sharded_engine|sharded_engine_events|counter_normalizer|metric_envelope_decode|metric_json_decode_baseline|metric_envelope_eventwriter_rows|metric_envelope_eventwriter_persist|metric_envelope_eventwriter_pipeline|metric_envelope_extract|metric_json_extract_baseline
#   ANOMALY_BENCH_SERIES=50000
#   ANOMALY_BENCH_BASELINE=12
#   ANOMALY_BENCH_WINDOW=300
#   ANOMALY_BENCH_ANOMALY=3
#   ANOMALY_BENCH_ROLLUP_SAMPLES_PER_EVAL=1
#   ANOMALY_BENCH_CONCURRENCY=16
#   ANOMALY_BENCH_BATCH_SIZE=1000
#   ANOMALY_BENCH_METRIC_SOURCE=generic|sysmon|snmp|icmp|mtr|sweep|rperf|plugin|addon|otel_derived
#   ANOMALY_BENCH_RUN_ID=<optional unique suffix for persistence runs>
#   ANOMALY_BENCH_PROFILE=true
#
# `owner` mode exercises the stateful ContextOwner + real CausalReasoner path.
# `legacy_list` mode exercises the old list-shaped NIF context. `reasoner`
# exercises the compact NIF state. `reasoner_batch*` modes amortize Rustler
# overhead across independent series while preserving per-series sample order.

defmodule ServiceRadar.Bench.AnomalyDetectionScale do
  @moduledoc false
  alias Ecto.Adapters.SQL.Sandbox
  alias ServiceRadar.EventWriter.Config, as: EventWriterConfig
  alias ServiceRadar.EventWriter.Processors.Metrics
  alias ServiceRadar.EventWriter.Processors.OtelMetrics
  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.Metric
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricPoint
  alias Serviceradar.Metric.V1.MetricResource
  alias Serviceradar.Metric.V1.StringMapEntry
  alias ServiceRadar.Observability.AnomalyDetection.ContextOwner
  alias ServiceRadar.Observability.AnomalyDetection.CounterNormalizer
  alias ServiceRadar.Observability.AnomalyDetection.NativeContextEngine
  alias ServiceRadar.Observability.AnomalyDetection.SampleExtractor
  alias ServiceRadar.Observability.AnomalyDetection.ShardedContextEngine
  alias ServiceRadar.Observability.CausalReasoner
  alias ServiceRadar.Observability.MetricEnvelope
  alias ServiceRadar.Repo

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
    metric_source = metric_benchmark_source()

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
    metric_source=#{metric_source}
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

    validate_result!(mode, result, series_count, anomaly_count)

    elapsed_ns = System.monotonic_time() - started_at
    :erlang.garbage_collect()
    memory_after = :erlang.memory(:total)

    elapsed_s = System.convert_time_unit(elapsed_ns, :native, :microsecond) / 1_000_000
    evals_per_s = result.evaluations / max(elapsed_s, 0.001)
    raw_samples_per_s = result.raw_samples / max(elapsed_s, 0.001)
    series_per_s = series_count / max(elapsed_s, 0.001)
    memory_delta_mb = (memory_after - memory_before) / 1_048_576
    profile = Map.get(result, :profile, %{})
    decoded_messages = Map.get(profile, :decoded_messages, 0)
    decoded_messages_per_s = decoded_messages / max(elapsed_s, 0.001)
    payload_mb = Map.get(profile, :payload_bytes, 0) / 1_048_576

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
    decoded_messages=#{decoded_messages}
    decoded_messages_per_second=#{round(decoded_messages_per_s)}
    payload_mb=#{Float.round(payload_mb, 2)}
    memory_delta_mb=#{Float.round(memory_delta_mb, 2)}
    """)

    print_profile(result, result.evaluations)
  end

  defp run_benchmark(
         "metric_envelope_decode",
         series_count,
         baseline_count,
         _window_size,
         anomaly_count,
         rollup_samples_per_eval,
         concurrency,
         batch_size
       ) do
    slot_count = baseline_count + anomaly_count
    shard_count = min(concurrency, slot_count)

    1..shard_count
    |> Task.async_stream(
      fn shard ->
        shard
        |> Range.new(slot_count, shard_count)
        |> Enum.reduce(
          %{evaluations: 0, raw_samples: 0, confirmed: 0, failed: 0, profile: %{}},
          fn slot, metrics ->
            1..series_count
            |> Enum.chunk_every(batch_size)
            |> Enum.reduce(metrics, fn chunk, metrics ->
              payload =
                metric_envelope_payload(chunk, slot, baseline_count, rollup_samples_per_eval)

              started_at = System.monotonic_time(:nanosecond)

              case MetricEnvelope.decode_rows(payload) do
                {:ok, rows} ->
                  decode_ns = System.monotonic_time(:nanosecond) - started_at
                  decoded = length(rows)

                  metrics
                  |> Map.update!(:evaluations, &(&1 + decoded))
                  |> Map.update!(:raw_samples, &(&1 + decoded * rollup_samples_per_eval))
                  |> update_profile(:decode_ns, decode_ns)
                  |> update_profile(:total_ns, decode_ns)
                  |> update_profile(:payload_bytes, byte_size(payload))
                  |> update_profile(:decoded_messages, 1)
                  |> update_profile(:decoded_rows, decoded)

                {:error, reason} ->
                  IO.puts("metric envelope decode failed: #{inspect(reason)}")
                  %{metrics | failed: metrics.failed + length(chunk)}
              end
            end)
          end
        )
      end,
      max_concurrency: shard_count,
      timeout: :infinity,
      ordered: false
    )
    |> reduce_task_results()
  end

  defp run_benchmark(
         "metric_json_decode_baseline",
         series_count,
         baseline_count,
         _window_size,
         anomaly_count,
         rollup_samples_per_eval,
         concurrency,
         batch_size
       ) do
    slot_count = baseline_count + anomaly_count
    shard_count = min(concurrency, slot_count)

    1..shard_count
    |> Task.async_stream(
      fn shard ->
        shard
        |> Range.new(slot_count, shard_count)
        |> Enum.reduce(
          %{evaluations: 0, raw_samples: 0, confirmed: 0, failed: 0, profile: %{}},
          fn slot, metrics ->
            1..series_count
            |> Enum.chunk_every(batch_size)
            |> Enum.reduce(metrics, fn chunk, metrics ->
              payload =
                metric_json_payload(chunk, slot, baseline_count, rollup_samples_per_eval)

              started_at = System.monotonic_time(:nanosecond)

              case decode_legacy_metric_json_rows(payload) do
                {:ok, rows} ->
                  decode_ns = System.monotonic_time(:nanosecond) - started_at
                  decoded = length(rows)

                  metrics
                  |> Map.update!(:evaluations, &(&1 + decoded))
                  |> Map.update!(:raw_samples, &(&1 + decoded * rollup_samples_per_eval))
                  |> update_profile(:decode_ns, decode_ns)
                  |> update_profile(:total_ns, decode_ns)
                  |> update_profile(:payload_bytes, byte_size(payload))
                  |> update_profile(:decoded_messages, 1)
                  |> update_profile(:decoded_rows, decoded)

                {:error, reason} ->
                  IO.puts("JSON metric baseline decode failed: #{inspect(reason)}")
                  %{metrics | failed: metrics.failed + length(chunk)}
              end
            end)
          end
        )
      end,
      max_concurrency: shard_count,
      timeout: :infinity,
      ordered: false
    )
    |> reduce_task_results()
  end

  defp run_benchmark(
         "metric_envelope_eventwriter_rows",
         series_count,
         baseline_count,
         _window_size,
         anomaly_count,
         rollup_samples_per_eval,
         concurrency,
         batch_size
       ) do
    slot_count = baseline_count + anomaly_count
    shard_count = min(concurrency, slot_count)

    1..shard_count
    |> Task.async_stream(
      fn shard ->
        shard
        |> Range.new(slot_count, shard_count)
        |> Enum.reduce(
          %{evaluations: 0, raw_samples: 0, confirmed: 0, failed: 0, profile: %{}},
          fn slot, metrics ->
            1..series_count
            |> Enum.chunk_every(batch_size)
            |> Enum.reduce(metrics, fn chunk, metrics ->
              payload =
                metric_envelope_payload(chunk, slot, baseline_count, rollup_samples_per_eval)

              started_at = System.monotonic_time(:nanosecond)

              rows = parse_metric_benchmark_rows(payload)

              eventwriter_ns = System.monotonic_time(:nanosecond) - started_at
              decoded = length(List.wrap(rows))

              metrics
              |> Map.update!(:evaluations, &(&1 + decoded))
              |> Map.update!(:raw_samples, &(&1 + decoded * rollup_samples_per_eval))
              |> update_profile(:eventwriter_rows_ns, eventwriter_ns)
              |> update_profile(:total_ns, eventwriter_ns)
              |> update_profile(:payload_bytes, byte_size(payload))
              |> update_profile(:decoded_messages, 1)
              |> update_profile(:decoded_rows, decoded)
            end)
          end
        )
      end,
      max_concurrency: shard_count,
      timeout: :infinity,
      ordered: false
    )
    |> reduce_task_results()
  end

  defp run_benchmark(
         "metric_envelope_eventwriter_persist",
         series_count,
         baseline_count,
         _window_size,
         anomaly_count,
         rollup_samples_per_eval,
         concurrency,
         batch_size
       ) do
    ensure_repo_started!()

    slot_count = baseline_count + anomaly_count
    shard_count = min(concurrency, slot_count)

    1..shard_count
    |> Task.async_stream(
      fn shard ->
        shard
        |> Range.new(slot_count, shard_count)
        |> Enum.reduce(
          %{evaluations: 0, raw_samples: 0, confirmed: 0, failed: 0, profile: %{}},
          fn slot, metrics ->
            1..series_count
            |> Enum.chunk_every(batch_size)
            |> Enum.reduce(metrics, fn chunk, metrics ->
              payload =
                metric_envelope_payload(chunk, slot, baseline_count, rollup_samples_per_eval)

              message = %{
                data: payload,
                metadata: %{subject: "metrics.benchmark", source: "benchmark"}
              }

              started_at = System.monotonic_time(:nanosecond)

              case Metrics.process_batch([message]) do
                {:ok, count} ->
                  persistence_ns = System.monotonic_time(:nanosecond) - started_at

                  metrics
                  |> Map.update!(:evaluations, &(&1 + count))
                  |> Map.update!(:raw_samples, &(&1 + count * rollup_samples_per_eval))
                  |> update_profile(:persistence_ns, persistence_ns)
                  |> update_profile(:total_ns, persistence_ns)
                  |> update_profile(:payload_bytes, byte_size(payload))
                  |> update_profile(:decoded_messages, 1)
                  |> update_profile(:decoded_rows, count)

                {:error, reason} ->
                  IO.puts("metric envelope EventWriter persistence failed: #{inspect(reason)}")
                  %{metrics | failed: metrics.failed + length(chunk)}
              end
            end)
          end
        )
      end,
      max_concurrency: shard_count,
      timeout: :infinity,
      ordered: false
    )
    |> reduce_task_results()
  end

  defp run_benchmark(
         "metric_envelope_eventwriter_pipeline",
         series_count,
         baseline_count,
         _window_size,
         anomaly_count,
         rollup_samples_per_eval,
         _concurrency,
         batch_size
       ) do
    ensure_repo_started!()

    run_id = ensure_metric_run_id()
    slot_count = baseline_count + anomaly_count
    expected_rows = series_count * slot_count
    nats = metric_benchmark_nats()

    {:ok, publisher} = Gnat.start_link(%{host: nats.host, port: nats.port})

    config = metric_pipeline_config(nats, batch_size)
    {:ok, pipeline} = ServiceRadar.EventWriter.Pipeline.start_link(config)

    wait_for_stream!(publisher, "metrics", 10_000)

    payloads =
      for slot <- 1..slot_count,
          chunk <- Enum.chunk_every(1..series_count, batch_size) do
        metric_envelope_payload(chunk, slot, baseline_count, rollup_samples_per_eval)
      end

    started_at = System.monotonic_time(:nanosecond)
    publish_started_at = System.monotonic_time(:nanosecond)

    payloads
    |> Enum.with_index(1)
    |> Enum.each(fn {payload, index} ->
      headers = [{"Nats-Msg-Id", "metric-pipeline-bench-#{run_id}-#{index}"}]
      :ok = Gnat.pub(publisher, "metrics.benchmark", payload, headers: headers)
    end)

    publish_ns = System.monotonic_time(:nanosecond) - publish_started_at

    persisted_rows =
      wait_for_metric_rows!(run_id, expected_rows, metric_pipeline_timeout_ms())

    pipeline_ns = System.monotonic_time(:nanosecond) - started_at

    shutdown_pipeline(pipeline)
    Process.exit(publisher, :normal)

    %{
      evaluations: persisted_rows,
      raw_samples: persisted_rows * rollup_samples_per_eval,
      confirmed: 0,
      failed: max(expected_rows - persisted_rows, 0),
      profile: %{
        pipeline_wall_ns: pipeline_ns,
        publish_ns: publish_ns,
        total_ns: pipeline_ns,
        payload_bytes: Enum.reduce(payloads, 0, fn payload, acc -> acc + byte_size(payload) end),
        decoded_messages: length(payloads),
        decoded_rows: persisted_rows
      }
    }
  end

  defp run_benchmark(
         "metric_envelope_extract",
         series_count,
         baseline_count,
         _window_size,
         anomaly_count,
         rollup_samples_per_eval,
         concurrency,
         batch_size
       ) do
    slot_count = baseline_count + anomaly_count
    shard_count = min(concurrency, slot_count)

    1..shard_count
    |> Task.async_stream(
      fn shard ->
        shard
        |> Range.new(slot_count, shard_count)
        |> Enum.reduce(
          %{evaluations: 0, raw_samples: 0, confirmed: 0, failed: 0, profile: %{}},
          fn slot, metrics ->
            1..series_count
            |> Enum.chunk_every(batch_size)
            |> Enum.reduce(metrics, fn chunk, metrics ->
              payload =
                metric_envelope_payload(chunk, slot, baseline_count, rollup_samples_per_eval)

              started_at = System.monotonic_time(:nanosecond)

              samples =
                SampleExtractor.extract(%{
                  data: payload,
                  metadata: %{
                    subject: metric_benchmark_subject(),
                    source: metric_benchmark_source()
                  }
                })

              extract_ns = System.monotonic_time(:nanosecond) - started_at
              extracted = length(samples)

              metrics
              |> Map.update!(:evaluations, &(&1 + extracted))
              |> Map.update!(:raw_samples, &(&1 + extracted * rollup_samples_per_eval))
              |> update_profile(:extract_ns, extract_ns)
              |> update_profile(:total_ns, extract_ns)
              |> update_profile(:payload_bytes, byte_size(payload))
              |> update_profile(:decoded_messages, 1)
              |> update_profile(:decoded_rows, extracted)
            end)
          end
        )
      end,
      max_concurrency: shard_count,
      timeout: :infinity,
      ordered: false
    )
    |> reduce_task_results()
  end

  defp run_benchmark(
         "metric_json_extract_baseline",
         series_count,
         baseline_count,
         _window_size,
         anomaly_count,
         rollup_samples_per_eval,
         concurrency,
         batch_size
       ) do
    slot_count = baseline_count + anomaly_count
    shard_count = min(concurrency, slot_count)

    1..shard_count
    |> Task.async_stream(
      fn shard ->
        shard
        |> Range.new(slot_count, shard_count)
        |> Enum.reduce(
          %{evaluations: 0, raw_samples: 0, confirmed: 0, failed: 0, profile: %{}},
          fn slot, metrics ->
            1..series_count
            |> Enum.chunk_every(batch_size)
            |> Enum.reduce(metrics, fn chunk, metrics ->
              payload =
                metric_json_payload(chunk, slot, baseline_count, rollup_samples_per_eval)

              started_at = System.monotonic_time(:nanosecond)

              case decode_legacy_metric_json_rows(payload) do
                {:ok, rows} ->
                  samples = legacy_timeseries_samples(rows, "metrics.benchmark")
                  extract_ns = System.monotonic_time(:nanosecond) - started_at
                  extracted = length(samples)

                  metrics
                  |> Map.update!(:evaluations, &(&1 + extracted))
                  |> Map.update!(:raw_samples, &(&1 + extracted * rollup_samples_per_eval))
                  |> update_profile(:extract_ns, extract_ns)
                  |> update_profile(:total_ns, extract_ns)
                  |> update_profile(:payload_bytes, byte_size(payload))
                  |> update_profile(:decoded_messages, 1)
                  |> update_profile(:decoded_rows, extracted)

                {:error, reason} ->
                  IO.puts("JSON metric baseline extract failed: #{inspect(reason)}")
                  %{metrics | failed: metrics.failed + length(chunk)}
              end
            end)
          end
        )
      end,
      max_concurrency: shard_count,
      timeout: :infinity,
      ordered: false
    )
    |> reduce_task_results()
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

  defp update_profile(metrics, key, value) do
    Map.update(metrics, :profile, %{key => value}, fn profile ->
      Map.update(profile, key, value, &(&1 + value))
    end)
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
        :decode_ns,
        :eventwriter_rows_ns,
        :extract_ns,
        :persistence_ns,
        :pipeline_wall_ns,
        :publish_ns,
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
    decoded_messages=#{Map.get(profile, :decoded_messages, 0)}
    decoded_rows=#{Map.get(profile, :decoded_rows, 0)}
    payload_bytes=#{Map.get(profile, :payload_bytes, 0)}
    """)
  end

  defp print_profile(_result, _evaluations), do: :ok

  defp validate_result!(
         "metric_envelope_decode",
         %{failed: failed, confirmed: confirmed},
         _series,
         _anomaly
       ) do
    if failed != 0 or confirmed != 0 do
      raise "benchmark correctness check failed: expected metric_envelope_decode confirmed=0 failed=0, got confirmed=#{confirmed} failed=#{failed}"
    end
  end

  defp validate_result!(
         "metric_json_decode_baseline",
         %{failed: failed, confirmed: confirmed},
         _series,
         _anomaly
       ) do
    if failed != 0 or confirmed != 0 do
      raise "benchmark correctness check failed: expected metric_json_decode_baseline confirmed=0 failed=0, got confirmed=#{confirmed} failed=#{failed}"
    end
  end

  defp validate_result!(
         "metric_envelope_eventwriter_rows",
         %{failed: failed, confirmed: confirmed},
         _series,
         _anomaly
       ) do
    if failed != 0 or confirmed != 0 do
      raise "benchmark correctness check failed: expected metric_envelope_eventwriter_rows confirmed=0 failed=0, got confirmed=#{confirmed} failed=#{failed}"
    end
  end

  defp validate_result!(
         "metric_envelope_eventwriter_persist",
         %{failed: failed, confirmed: confirmed},
         _series,
         _anomaly
       ) do
    if failed != 0 or confirmed != 0 do
      raise "benchmark correctness check failed: expected metric_envelope_eventwriter_persist confirmed=0 failed=0, got confirmed=#{confirmed} failed=#{failed}"
    end
  end

  defp validate_result!(
         "metric_envelope_eventwriter_pipeline",
         %{failed: failed, confirmed: confirmed},
         _series,
         _anomaly
       ) do
    if failed != 0 or confirmed != 0 do
      raise "benchmark correctness check failed: expected metric_envelope_eventwriter_pipeline confirmed=0 failed=0, got confirmed=#{confirmed} failed=#{failed}"
    end
  end

  defp validate_result!(
         "metric_envelope_extract",
         %{failed: failed, confirmed: confirmed},
         _series,
         _anomaly
       ) do
    if failed != 0 or confirmed != 0 do
      raise "benchmark correctness check failed: expected metric_envelope_extract confirmed=0 failed=0, got confirmed=#{confirmed} failed=#{failed}"
    end
  end

  defp validate_result!(
         "metric_json_extract_baseline",
         %{failed: failed, confirmed: confirmed},
         _series,
         _anomaly
       ) do
    if failed != 0 or confirmed != 0 do
      raise "benchmark correctness check failed: expected metric_json_extract_baseline confirmed=0 failed=0, got confirmed=#{confirmed} failed=#{failed}"
    end
  end

  defp validate_result!(
         "counter_normalizer",
         %{failed: failed, confirmed: confirmed},
         _series,
         _anomaly
       ) do
    if failed != 0 or confirmed != 0 do
      raise "benchmark correctness check failed: expected counter_normalizer confirmed=0 failed=0, got confirmed=#{confirmed} failed=#{failed}"
    end
  end

  defp validate_result!(
         mode,
         %{failed: failed, confirmed: confirmed},
         series_count,
         anomaly_count
       ) do
    expected = expected_confirmed(mode, series_count, anomaly_count)

    cond do
      failed != 0 ->
        raise "benchmark correctness check failed: expected failed=0, got failed=#{failed}"

      confirmed != expected ->
        raise "benchmark correctness check failed: expected confirmed=#{expected}, got confirmed=#{confirmed} for mode=#{mode}"

      true ->
        :ok
    end
  end

  defp expected_confirmed(mode, series_count, anomaly_count) do
    confirmed_slots =
      anomaly_count
      |> Kernel.-(Keyword.fetch!(@detector_opts, :confirm_slots))
      |> Kernel.+(1)
      |> max(0)

    if sparse_state_change_mode?(mode) do
      if confirmed_slots > 0, do: series_count, else: 0
    else
      series_count * confirmed_slots
    end
  end

  defp sparse_state_change_mode?(mode) do
    mode in [
      "reasoner_state_values_changes_shards",
      "reasoner_state_value_tuples_changes_shards",
      "native_engine_events",
      "native_engine_compact_events",
      "native_engine_prepared_shards",
      "sharded_engine_events"
    ]
  end

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
    raise "unsupported ANOMALY_BENCH_MODE=#{inspect(mode)}; expected owner, legacy_list, reasoner, reasoner_batch, reasoner_batch_shards, reasoner_state_batch_shards, reasoner_state_values_changes_shards, reasoner_state_value_tuples_changes_shards, native_engine_events, native_engine_compact_events, native_engine_prepared_shards, sharded_engine, sharded_engine_events, counter_normalizer, metric_envelope_decode, metric_json_decode_baseline, metric_envelope_eventwriter_rows, metric_envelope_eventwriter_persist, metric_envelope_eventwriter_pipeline, metric_envelope_extract, or metric_json_extract_baseline"
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

  defp metric_envelope_payload(indexes, slot, baseline_count, rollup_samples_per_eval) do
    source = metric_benchmark_source()

    metrics =
      Enum.map(indexes, fn index ->
        dataset = dataset(index)
        value = slot_value(dataset, slot, baseline_count, rollup_samples_per_eval)

        metric_for_source(source, index, dataset, value, slot)
      end)

    MetricBatch.encode(%MetricBatch{
      schema_version: "serviceradar.metric.v1",
      resource: metric_resource_for_source(source),
      ingest_identity: %IngestIdentity{
        source: metric_ingest_source(source),
        payload_kind: "serviceradar.metric.v1",
        producer_id: "bench",
        producer_kind: metric_producer_kind(source)
      },
      emitted_at_unix_nano: System.system_time(:nanosecond),
      metrics: metrics
    })
  end

  defp metric_pipeline_config(nats, batch_size) do
    %EventWriterConfig{
      enabled: true,
      nats: %{
        host: nats.host,
        port: nats.port,
        user: nil,
        password: nil,
        tls: false,
        jwt: nil,
        nkey_seed: nil,
        creds_file: nil
      },
      batch_size: batch_size,
      batch_timeout: 100,
      consumer_name: "metric-envelope-bench-#{System.unique_integer([:positive])}",
      producer_name: :"metric_envelope_bench_producer_#{System.unique_integer([:positive])}",
      streams: [
        %{
          name: "METRICS",
          stream_name: "metrics",
          subject: "metrics.>",
          processor: Metrics,
          batch_size: batch_size,
          batch_timeout: 100,
          stream_retention: "limits",
          stream_storage: "memory",
          stream_discard: "old",
          stream_max_bytes: 1_073_741_824,
          stream_max_age: 1_800_000_000_000,
          consumer_max_deliver: 5,
          consumer_deliver_policy: :new,
          consumer_inactive_threshold: 30_000_000_000
        }
      ]
    }
  end

  defp wait_for_stream!(conn, stream, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    wait_until!(deadline, "JetStream stream #{stream} was not ready", fn ->
      case Gnat.request(conn, "$JS.API.STREAM.INFO.#{stream}", "", receive_timeout: 1_000) do
        {:ok, %{body: body}} ->
          case Jason.decode(body) do
            {:ok, %{"error" => _}} -> false
            {:ok, %{"config" => %{"name" => ^stream}}} -> true
            {:ok, %{"config" => %{"name" => other}}} -> other == stream
            _ -> false
          end

        _ ->
          false
      end
    end)
  end

  defp wait_for_metric_rows!(run_id, expected_rows, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    wait_until!(deadline, "metric rows for run #{run_id} did not reach #{expected_rows}", fn ->
      persisted_metric_rows(run_id) >= expected_rows
    end)

    persisted_metric_rows(run_id)
  end

  defp persisted_metric_rows(run_id) do
    like = "%:run:#{run_id}"

    case Repo.query(
           "SELECT count(*) FROM platform.timeseries_metrics WHERE series_key LIKE $1",
           [like],
           timeout: :infinity
         ) do
      {:ok, %{rows: [[count]]}} -> count
      _ -> 0
    end
  end

  defp ensure_repo_started! do
    _ = Application.ensure_all_started(:telemetry)
    _ = Application.ensure_all_started(:db_connection)
    _ = Application.ensure_all_started(:postgrex)
    _ = Application.ensure_all_started(:ecto_sql)

    if is_nil(Process.whereis(Repo)) do
      case Repo.start_link() do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    else
      :ok
    end

    configure_repo_sandbox!()
  end

  defp configure_repo_sandbox! do
    if Keyword.get(Repo.config(), :pool) == Sandbox do
      Sandbox.mode(Repo, {:shared, self()})
    end

    :ok
  end

  defp wait_until!(deadline, error_message, fun) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise error_message

      true ->
        Process.sleep(100)
        wait_until!(deadline, error_message, fun)
    end
  end

  defp shutdown_pipeline(pid) when is_pid(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :normal)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      1_000 ->
        Process.demonitor(ref, [:flush])
        :ok
    end
  end

  defp ensure_metric_run_id do
    case System.get_env("ANOMALY_BENCH_RUN_ID") do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        value = "pipeline_#{System.system_time(:second)}_#{System.unique_integer([:positive])}"
        System.put_env("ANOMALY_BENCH_RUN_ID", value)
        value
    end
  end

  defp metric_benchmark_nats do
    uri = URI.parse(System.get_env("ANOMALY_BENCH_NATS_URL", "nats://127.0.0.1:4222"))

    %{
      host: uri.host || "127.0.0.1",
      port: uri.port || 4222
    }
  end

  defp metric_pipeline_timeout_ms do
    env_int("ANOMALY_BENCH_PIPELINE_TIMEOUT_MS", 60_000)
  end

  defp metric_for_source("sysmon", index, dataset, value, slot) do
    series_key = metric_series_key(dataset)

    %Metric{
      name: metric_name(dataset),
      metric_type: dataset.metric_class,
      kind: :METRIC_KIND_GAUGE,
      temporality: :METRIC_TEMPORALITY_UNSPECIFIED,
      unit: metric_unit(dataset),
      tags: metric_entries(%{"bench_series" => Integer.to_string(index)}),
      metadata: metric_entries(%{"host_identity" => "bench-agent"}),
      points: [
        metric_point(value, slot, dataset.series_key,
          series_key: series_key,
          attributes: %{"series_key" => series_key}
        )
      ]
    }
  end

  defp metric_for_source("snmp", index, dataset, value, slot) do
    if_index = rem(index, 512) + 1
    raw_value = round(1_000_000_000_000 + slot * 1_000 + index)
    series_key = metric_series_key(dataset)

    %Metric{
      name: "ifHCInOctets",
      metric_type: "snmp",
      kind: :METRIC_KIND_SUM,
      temporality: :METRIC_TEMPORALITY_CUMULATIVE,
      is_monotonic: true,
      unit: "By",
      counter_width: 64,
      tags:
        metric_entries(%{
          "bench_series" => Integer.to_string(index),
          "target" => "router-#{rem(index, 256)}",
          "host" => "10.0.#{div(index, 256)}.#{rem(index, 256)}"
        }),
      metadata: metric_entries(%{"oid" => ".1.3.6.1.2.1.31.1.1.1.6.#{if_index}"}),
      points: [
        metric_point(value, slot, dataset.series_key,
          series_key: series_key,
          raw_value: Integer.to_string(raw_value),
          raw_value_type: :METRIC_VALUE_TYPE_UINT64,
          if_index: if_index,
          interface_uid: "ifindex:#{if_index}",
          attributes: %{"series_key" => series_key}
        )
      ]
    }
  end

  defp metric_for_source("plugin", index, dataset, value, slot) do
    series_key = metric_series_key(dataset)

    %Metric{
      name: "proxmox_guest_cpu_ratio_max",
      metric_type: "cpu",
      kind: :METRIC_KIND_GAUGE,
      temporality: :METRIC_TEMPORALITY_UNSPECIFIED,
      unit: "ratio",
      tags:
        metric_entries(%{
          "bench_series" => Integer.to_string(index),
          "producer_id" => "proxmox-inventory",
          "producer_kind" => "plugin_result"
        }),
      metadata: metric_entries(%{"status" => "WARNING"}),
      points: [
        metric_point(value / 100.0, slot, dataset.series_key,
          series_key: series_key,
          attributes: %{"series_key" => series_key}
        )
      ]
    }
  end

  defp metric_for_source("mtr", index, dataset, value, slot) do
    series_key = metric_series_key(dataset)
    hop = rem(index, 30) + 1

    %Metric{
      name: "mtr.hop.avg_us",
      metric_type: "mtr",
      kind: :METRIC_KIND_GAUGE,
      temporality: :METRIC_TEMPORALITY_UNSPECIFIED,
      unit: "us",
      tags:
        metric_entries(%{
          "bench_series" => Integer.to_string(index),
          "target" => "wan-#{rem(index, 256)}.example.net",
          "target_ip" => "203.0.113.#{rem(index, 256)}",
          "protocol" => if(rem(index, 2) == 0, do: "icmp", else: "udp"),
          "ip_version" => "4"
        }),
      metadata: metric_entries(%{"total_hops" => Integer.to_string(30)}),
      points: [
        metric_point(value * 1_000.0, slot, dataset.series_key,
          series_key: series_key,
          attributes: %{
            "series_key" => series_key,
            "hop_number" => Integer.to_string(hop),
            "addr" => "198.51.100.#{hop}",
            "hostname" => "hop-#{hop}.example.net",
            "device_id" => "sr:bench-device-#{index}"
          }
        )
      ]
    }
  end

  defp metric_for_source("sweep", index, dataset, value, slot) do
    series_key = metric_series_key(dataset)
    port = Enum.at([22, 80, 443, 8443], rem(index, 4))

    %Metric{
      name: "sweep.host.icmp_response_time_ns",
      metric_type: "sweep",
      kind: :METRIC_KIND_GAUGE,
      temporality: :METRIC_TEMPORALITY_UNSPECIFIED,
      unit: "ns",
      tags:
        metric_entries(%{
          "bench_series" => Integer.to_string(index),
          "network" => "bench-sweep",
          "execution_id" => "bench-exec-#{div(slot, 10)}",
          "sweep_group_id" => "bench-group",
          "port" => Integer.to_string(port)
        }),
      metadata:
        metric_entries(%{
          "scanner_path" => "raw",
          "protocol" => "icmp",
          "address_family" => "ipv4"
        }),
      points: [
        metric_point(value * 1_000_000.0, slot, dataset.series_key,
          series_key: series_key,
          raw_value: Float.to_string(value * 1_000_000.0),
          attributes: %{
            "series_key" => series_key,
            "target" => "10.20.#{div(index, 256)}.#{rem(index, 256)}",
            "hostname" => "sweep-host-#{index}",
            "network" => "bench-sweep"
          }
        )
      ]
    }
  end

  defp metric_for_source("rperf", index, dataset, value, slot) do
    series_key = metric_series_key(dataset)

    %Metric{
      name: "rperf.bits_per_second",
      metric_type: "rperf",
      kind: :METRIC_KIND_GAUGE,
      temporality: :METRIC_TEMPORALITY_UNSPECIFIED,
      unit: "bit/s",
      tags:
        metric_entries(%{
          "bench_series" => Integer.to_string(index),
          "target" => "rperf-target-#{rem(index, 512)}",
          "protocol" => if(rem(index, 2) == 0, do: "tcp", else: "udp"),
          "direction" => if(rem(index, 2) == 0, do: "upload", else: "download")
        }),
      metadata:
        metric_entries(%{
          "loss_percent" => Float.to_string(rem(index, 10) / 10.0),
          "jitter_ms" => Float.to_string(rem(index, 50) / 10.0)
        }),
      points: [
        metric_point(value * 1_000_000.0, slot, dataset.series_key,
          series_key: series_key,
          raw_value: Float.to_string(value * 1_000_000.0),
          attributes: %{
            "series_key" => series_key,
            "check_id" => "rperf-#{rem(index, 256)}",
            "check_name" => "rperf WAN #{rem(index, 256)}"
          }
        )
      ]
    }
  end

  defp metric_for_source("addon", index, dataset, value, slot) do
    series_key = metric_series_key(dataset)

    %Metric{
      name: "environment_temperature_celsius",
      metric_type: "environment.temperature",
      kind: :METRIC_KIND_GAUGE,
      temporality: :METRIC_TEMPORALITY_UNSPECIFIED,
      unit: "Cel",
      tags:
        metric_entries(%{
          "bench_series" => Integer.to_string(index),
          "producer_id" => "sample-native-addon",
          "producer_kind" => "native-addon",
          "sdk_language" => if(rem(index, 2) == 0, do: "go", else: "rust")
        }),
      metadata:
        metric_entries(%{
          "addon_id" => "environment-sensor",
          "telemetry_transport" => "AddonService.StreamTelemetry"
        }),
      points: [
        metric_point(18.0 + value / 20.0, slot, dataset.series_key,
          series_key: series_key,
          attributes: %{
            "series_key" => series_key,
            "sensor_id" => "sensor-#{rem(index, 128)}"
          }
        )
      ]
    }
  end

  defp metric_for_source("otel_derived", index, _dataset, value, slot) do
    span_id =
      index
      |> Integer.to_string(16)
      |> String.pad_leading(16, "0")
      |> String.slice(-16, 16)

    trace_id =
      index
      |> Integer.to_string(16)
      |> String.pad_leading(32, "0")
      |> String.slice(-32, 32)

    %Metric{
      name: "otel.span.duration_ms",
      metric_type: "otel_span_derived",
      kind: :METRIC_KIND_GAUGE,
      temporality: :METRIC_TEMPORALITY_UNSPECIFIED,
      unit: "ms",
      tags: metric_entries(%{"metric_family" => "otel_span_derived"}),
      points: [
        metric_point(
          value,
          slot,
          "otel:span_duration:svc-#{rem(index, 128)}:span-#{index}:#{span_id}",
          raw_value: Float.to_string(value),
          attributes: %{
            "service_name" => "svc-#{rem(index, 128)}",
            "span_name" => "span-#{index}",
            "span_kind" => "server",
            "http_method" => "GET",
            "http_route" => "/bench/:id",
            "http_status_code" => "200"
          },
          metadata: %{
            "timestamp" => DateTime.to_iso8601(DateTime.from_unix!(slot, :second)),
            "trace_id" => trace_id,
            "span_id" => span_id,
            "metric_type" => "span",
            "duration_seconds" => Float.to_string(value / 1_000.0),
            "is_slow" => if(value > 100.0, do: "true", else: "false"),
            "component" => "otel-collector",
            "level" => "info"
          }
        )
      ]
    }
  end

  defp metric_for_source("icmp", index, dataset, value, slot) do
    series_key = metric_series_key(dataset)

    %Metric{
      name: "icmp_response_time_ns",
      metric_type: "icmp",
      kind: :METRIC_KIND_GAUGE,
      temporality: :METRIC_TEMPORALITY_UNSPECIFIED,
      unit: "ns",
      tags:
        metric_entries(%{
          "bench_series" => Integer.to_string(index),
          "target" => "host-#{rem(index, 512)}",
          "target_ip" => "10.10.#{div(index, 256)}.#{rem(index, 256)}"
        }),
      metadata: metric_entries(%{"packet_loss_percent" => "0"}),
      points: [
        metric_point(value * 1_000_000.0, slot, dataset.series_key,
          series_key: series_key,
          raw_value: Float.to_string(value * 1_000_000.0),
          attributes: %{"series_key" => series_key}
        )
      ]
    }
  end

  defp metric_for_source(_source, index, dataset, value, slot) do
    series_key = metric_series_key(dataset)

    %Metric{
      name: metric_name(dataset),
      metric_type: dataset.metric_class,
      kind: :METRIC_KIND_GAUGE,
      temporality: :METRIC_TEMPORALITY_UNSPECIFIED,
      unit: metric_unit(dataset),
      tags: metric_entries(%{"bench_series" => Integer.to_string(index)}),
      points: [
        metric_point(value, slot, dataset.series_key,
          series_key: series_key,
          attributes: %{"series_key" => series_key}
        )
      ]
    }
  end

  defp metric_point(value, slot, default_series_key, opts) do
    series_key = Keyword.get(opts, :series_key, default_series_key)
    raw_value = Keyword.get(opts, :raw_value, Float.to_string(value))
    raw_value_type = Keyword.get(opts, :raw_value_type, :METRIC_VALUE_TYPE_DOUBLE)

    %MetricPoint{
      value: value,
      raw_value: raw_value,
      raw_value_type: raw_value_type,
      observed_at_unix_nano: slot * 1_000_000_000,
      series_identity_hint: series_key,
      if_index: Keyword.get(opts, :if_index, 0),
      interface_uid: Keyword.get(opts, :interface_uid, ""),
      attributes: opts |> Keyword.get(:attributes, %{}) |> metric_entries(),
      metadata: opts |> Keyword.get(:metadata, %{}) |> metric_entries()
    }
  end

  defp metric_series_key(dataset) do
    case System.get_env("ANOMALY_BENCH_RUN_ID") do
      value when is_binary(value) and value != "" -> "#{dataset.series_key}:run:#{value}"
      _ -> dataset.series_key
    end
  end

  defp metric_resource_for_source(source) do
    {service_name, service_type} = metric_service_identity(source)

    %MetricResource{
      agent_id: "bench-agent",
      gateway_id: "bench-gateway",
      partition: "bench",
      service_name: service_name,
      service_type: service_type,
      host_id: if(source == "sysmon", do: "bench-agent", else: ""),
      target_device_ip: if(source in ["snmp", "icmp", "sweep"], do: "10.0.0.1", else: "")
    }
  end

  defp metric_service_identity("sysmon"), do: {"sysmon", "sysmon"}
  defp metric_service_identity("snmp"), do: {"snmp", "snmp"}
  defp metric_service_identity("icmp"), do: {"icmp_checks", "icmp"}
  defp metric_service_identity("mtr"), do: {"mtr_traces", "mtr"}
  defp metric_service_identity("sweep"), do: {"network_sweep", "sweep"}
  defp metric_service_identity("rperf"), do: {"rperf", "rperf"}
  defp metric_service_identity("plugin"), do: {"proxmox-inventory", "wasm-plugin"}
  defp metric_service_identity("addon"), do: {"sample-native-addon", "native-addon"}
  defp metric_service_identity("otel_derived"), do: {"otel-derived", "otel"}
  defp metric_service_identity(source), do: {source, source}

  defp metric_ingest_source("sysmon"), do: "sysmon-metrics"
  defp metric_ingest_source("snmp"), do: "snmp-metrics"
  defp metric_ingest_source("icmp"), do: "icmp-metrics"
  defp metric_ingest_source("mtr"), do: "mtr-metrics"
  defp metric_ingest_source("sweep"), do: "sweep-metrics"
  defp metric_ingest_source("rperf"), do: "rperf-metrics"
  defp metric_ingest_source("plugin"), do: "plugin:benchmark"
  defp metric_ingest_source("addon"), do: "addon:benchmark"
  defp metric_ingest_source("otel_derived"), do: "otel-metrics-derived"
  defp metric_ingest_source(source), do: source

  defp metric_producer_kind("sysmon"), do: "agent-sysmon"
  defp metric_producer_kind("snmp"), do: "agent-snmp"
  defp metric_producer_kind("icmp"), do: "agent-icmp"
  defp metric_producer_kind("mtr"), do: "agent-mtr"
  defp metric_producer_kind("sweep"), do: "agent-sweep"
  defp metric_producer_kind("rperf"), do: "rperf-checker"
  defp metric_producer_kind("plugin"), do: "wasm-plugin"
  defp metric_producer_kind("addon"), do: "native-addon"
  defp metric_producer_kind("otel_derived"), do: "otel-collector"
  defp metric_producer_kind(_source), do: "benchmark"

  defp metric_benchmark_subject do
    case metric_benchmark_source() do
      "otel_derived" -> "otel.metrics.derived"
      _source -> "metrics.benchmark"
    end
  end

  defp parse_metric_benchmark_rows(payload) do
    metadata = %{subject: metric_benchmark_subject(), source: metric_benchmark_source()}

    case metric_benchmark_source() do
      "otel_derived" -> OtelMetrics.parse_message(%{data: payload, metadata: metadata})
      _source -> Metrics.parse_message(%{data: payload, metadata: metadata})
    end
  end

  defp metric_json_payload(indexes, slot, baseline_count, rollup_samples_per_eval) do
    metrics =
      Enum.map(indexes, fn index ->
        dataset = dataset(index)
        value = slot_value(dataset, slot, baseline_count, rollup_samples_per_eval)

        %{
          "name" => metric_name(dataset),
          "metric_type" => dataset.metric_class,
          "kind" => "gauge",
          "temporality" => nil,
          "is_monotonic" => false,
          "unit" => metric_unit(dataset),
          "tags" => %{"bench_series" => Integer.to_string(index)},
          "metadata" => %{},
          "points" => [
            %{
              "value" => value,
              "raw_value" => Float.to_string(value),
              "raw_value_type" => "double",
              "observed_at_unix_nano" => slot * 1_000_000_000,
              "series_identity_hint" => dataset.series_key,
              "attributes" => %{"series_key" => dataset.series_key},
              "metadata" => %{}
            }
          ]
        }
      end)

    Jason.encode!(%{
      "schema_version" => "serviceradar.metric.v1",
      "resource" => %{
        "agent_id" => "bench-agent",
        "gateway_id" => "bench-gateway",
        "partition" => "bench",
        "service_name" => "metric-envelope-decode",
        "service_type" => "benchmark"
      },
      "ingest_identity" => %{
        "source" => "bench",
        "payload_kind" => "serviceradar.metric.v1",
        "producer_id" => "bench",
        "producer_kind" => "benchmark"
      },
      "emitted_at_unix_nano" => System.system_time(:nanosecond),
      "metrics" => metrics
    })
  end

  defp decode_legacy_metric_json_rows(payload) do
    with {:ok, decoded} <- Jason.decode(payload) do
      resource = decoded["resource"] || %{}
      ingest_identity = decoded["ingest_identity"] || %{}
      created_at = DateTime.utc_now()

      rows =
        Enum.flat_map(decoded["metrics"] || [], fn metric ->
          Enum.map(metric["points"] || [], fn point ->
            legacy_metric_row(decoded, resource, ingest_identity, metric, point, created_at)
          end)
        end)

      {:ok, rows}
    end
  end

  defp legacy_metric_row(batch, resource, ingest_identity, metric, point, created_at) do
    tags =
      (metric["tags"] || %{})
      |> Map.merge(point["attributes"] || %{})
      |> maybe_json_put("source", ingest_identity["source"])
      |> maybe_json_put("payload_kind", ingest_identity["payload_kind"])
      |> maybe_json_put("producer_id", ingest_identity["producer_id"])
      |> maybe_json_put("producer_kind", ingest_identity["producer_kind"])
      |> maybe_json_put("interface_uid", point["interface_uid"])

    metadata =
      (metric["metadata"] || %{})
      |> Map.merge(point["metadata"] || %{})
      |> maybe_json_put("schema", batch["schema_version"])
      |> maybe_json_put("kind", metric["kind"])
      |> maybe_json_put("temporality", metric["temporality"])
      |> maybe_json_put("is_monotonic", metric["is_monotonic"])
      |> maybe_json_put("raw_value", point["raw_value"])
      |> maybe_json_put("raw_value_type", point["raw_value_type"])
      |> maybe_json_put("counter_width", metric["counter_width"])
      |> maybe_json_put("start_time_unix_nano", point["start_time_unix_nano"])
      |> maybe_json_put("reset_anchor", point["reset_anchor"])
      |> maybe_json_put("ingress_id", batch["ingress_id"])
      |> maybe_json_put("ingress_timestamp_unix_nano", batch["ingress_timestamp_unix_nano"])

    %{
      timestamp: unix_nano_to_datetime(point["observed_at_unix_nano"]),
      gateway_id: resource["gateway_id"] || "unknown",
      agent_id: resource["agent_id"],
      metric_name: metric["name"] || "unknown",
      metric_type: metric["metric_type"] || metric["kind"] || "gauge",
      value: point["value"],
      unit: metric["unit"],
      tags: tags,
      partition: resource["partition"],
      is_delta: metric["temporality"] == "delta",
      target_device_ip: resource["target_device_ip"] || tags["target"] || tags["host"],
      if_index: positive_json(point["if_index"]),
      metadata: metadata,
      created_at: created_at,
      series_key: point["series_identity_hint"]
    }
  end

  defp legacy_timeseries_samples(rows, subject) do
    Enum.map(rows, fn row ->
      timestamp = timestamp_nano(row.timestamp)
      value = row.value * 1.0
      metric_class = row.metric_type || "timeseries"
      series_key = "#{metric_class}:#{row.series_key}"
      sample_hash = stable_sample_hash([series_key, timestamp, subject, value])

      %{
        series_key: series_key,
        event_id: sample_hash,
        order_key: {timestamp || 0, sample_hash, timestamp || 0, sample_hash},
        value: value,
        observed_at_unix_nano: timestamp,
        subject: subject,
        metric_class: metric_class,
        metadata: row
      }
    end)
  end

  defp timestamp_nano(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :nanosecond)
  defp timestamp_nano(value) when is_integer(value), do: value
  defp timestamp_nano(_value), do: nil

  defp stable_sample_hash(parts) do
    parts
    |> Enum.map_join("|", &to_string/1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp unix_nano_to_datetime(value) when is_integer(value) and value > 0 do
    case DateTime.from_unix(value, :nanosecond) do
      {:ok, datetime} -> datetime
      _ -> DateTime.utc_now()
    end
  end

  defp unix_nano_to_datetime(_value), do: DateTime.utc_now()

  defp maybe_json_put(map, _key, nil), do: map
  defp maybe_json_put(map, _key, ""), do: map
  defp maybe_json_put(map, _key, 0), do: map
  defp maybe_json_put(map, key, value), do: Map.put_new(map, key, value)

  defp positive_json(value) when is_integer(value) and value > 0, do: value
  defp positive_json(_value), do: nil

  defp metric_entries(map) do
    Enum.map(map, fn {key, value} -> %StringMapEntry{key: key, value: value} end)
  end

  defp metric_name(%{metric_class: "sysmon.cpu"}), do: "cpu.usage_percent"
  defp metric_name(%{metric_class: "sysmon.memory"}), do: "memory.used_percent"
  defp metric_name(%{metric_class: "sysmon.disk"}), do: "disk.used_percent"
  defp metric_name(%{metric_class: "flow"}), do: "network.bytes_per_second"
  defp metric_name(_dataset), do: "metric.value"

  defp metric_unit(%{metric_class: "flow"}), do: "By/s"
  defp metric_unit(_dataset), do: "%"

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

  defp metric_benchmark_source do
    case "ANOMALY_BENCH_METRIC_SOURCE" |> System.get_env("generic") |> String.downcase() do
      source
      when source in [
             "generic",
             "sysmon",
             "snmp",
             "icmp",
             "mtr",
             "sweep",
             "rperf",
             "plugin",
             "addon",
             "otel_derived"
           ] ->
        source

      _other ->
        "generic"
    end
  end

  defmodule NoopCheckpoint do
    @moduledoc false

    def load(_series_key, _opts), do: {:ok, nil}
    def save(_series_key, _checkpoint, _opts), do: :ok
  end
end

ServiceRadar.Bench.AnomalyDetectionScale.run()
