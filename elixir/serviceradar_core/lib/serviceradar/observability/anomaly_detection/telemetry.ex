defmodule ServiceRadar.Observability.AnomalyDetection.Telemetry do
  @moduledoc """
  Low-cardinality telemetry helpers for the anomaly detection hot path.
  """

  @batch_completed [:serviceradar, :anomaly_detection, :batch, :completed]
  @engine :native_context_engine

  @type path ::
          :events
          | :events_profiled
          | :compact_events
          | :compact_events_profiled
          | :prepared_shards

  @spec emit_batch_completed(path(), integer(), non_neg_integer(), [term()]) :: :ok
  def emit_batch_completed(path, started_at, input_samples, results)
      when is_atom(path) and is_integer(started_at) and is_integer(input_samples) and
             input_samples >= 0 and
             is_list(results) do
    now = System.monotonic_time()
    stats = result_stats(results)

    :telemetry.execute(
      @batch_completed,
      %{
        count: 1,
        duration: now - started_at,
        input_samples: input_samples,
        evaluations: max(input_samples - stats.duplicate_drops - stats.dropped_samples, 0),
        emitted_events: stats.emitted_events,
        duplicate_drops: stats.duplicate_drops,
        dropped_samples: stats.dropped_samples,
        failed_samples: stats.failed_samples,
        output_results: length(results)
      },
      %{engine: @engine, path: path}
    )
  end

  defp result_stats(results) do
    Enum.reduce(
      results,
      %{emitted_events: 0, duplicate_drops: 0, dropped_samples: 0, failed_samples: 0},
      fn result, acc ->
        case result_status(result) do
          {:ok, _verdict} ->
            Map.update!(acc, :emitted_events, &(&1 + 1))

          {:drop, :duplicate_event} ->
            Map.update!(acc, :duplicate_drops, &(&1 + 1))

          {:drop, _reason} ->
            Map.update!(acc, :dropped_samples, &(&1 + 1))

          {:error, _reason} ->
            Map.update!(acc, :failed_samples, &(&1 + 1))

          _other ->
            acc
        end
      end
    )
  end

  defp result_status({_sample, status}), do: status
  defp result_status(_result), do: :unknown
end
