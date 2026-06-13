# Synthetic anomaly detection scale benchmark.
#
# Run from elixir/serviceradar_core:
#
#   MIX_ENV=test mix run --no-start bench/anomaly_detection_scale.exs
#
# Useful knobs:
#
#   ANOMALY_BENCH_MODE=owner|reasoner
#   ANOMALY_BENCH_SERIES=50000
#   ANOMALY_BENCH_BASELINE=12
#   ANOMALY_BENCH_WINDOW=300
#   ANOMALY_BENCH_ANOMALY=3
#   ANOMALY_BENCH_ROLLUP_SAMPLES_PER_EVAL=1
#   ANOMALY_BENCH_CONCURRENCY=16
#
# `owner` mode exercises the stateful ContextOwner + real CausalReasoner path.
# `reasoner` mode exercises the NIF/statistical reasoner only and is an upper
# bound for per-sample compute throughput without GenServer/process overhead.

defmodule ServiceRadar.Bench.AnomalyDetectionScale do
  @moduledoc false
  alias ServiceRadar.Observability.AnomalyDetection.ContextOwner
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

    IO.puts("""
    ServiceRadar anomaly detection synthetic scale benchmark
    mode=#{mode}
    series=#{series_count}
    baseline_samples_per_series=#{baseline_count}
    window_size=#{window_size}
    anomaly_samples_per_series=#{anomaly_count}
    rollup_samples_per_eval=#{rollup_samples_per_eval}
    concurrency=#{concurrency}
    """)

    :erlang.garbage_collect()
    memory_before = :erlang.memory(:total)
    started_at = System.monotonic_time()

    result =
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
      |> Enum.reduce(%{evaluations: 0, raw_samples: 0, confirmed: 0, failed: 0}, fn
        {:ok, metrics}, acc ->
          %{
            evaluations: acc.evaluations + metrics.evaluations,
            raw_samples: acc.raw_samples + metrics.raw_samples,
            confirmed: acc.confirmed + metrics.confirmed,
            failed: acc.failed
          }

        {:exit, reason}, acc ->
          IO.puts("series task failed: #{inspect(reason)}")
          %{acc | failed: acc.failed + 1}
      end)

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
    memory_delta_mb=#{Float.round(memory_delta_mb, 2)}
    """)
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
         "reasoner",
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

        {evaluations + 1, confirmed + confirmed?(verdict), fold_context(context, value, verdict)}
      end)

    %{evaluations: evaluations, raw_samples: raw_samples, confirmed: confirmed}
  end

  defp run_series(_index, mode, _baseline_count, _window_size, _anomaly_count, _rollup_samples) do
    raise "unsupported ANOMALY_BENCH_MODE=#{inspect(mode)}; expected owner or reasoner"
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

  defp fold_context(context, value, verdict) do
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

  defmodule NoopCheckpoint do
    @moduledoc false

    def load(_series_key, _opts), do: {:ok, nil}
    def save(_series_key, _checkpoint, _opts), do: :ok
  end
end

ServiceRadar.Bench.AnomalyDetectionScale.run()
