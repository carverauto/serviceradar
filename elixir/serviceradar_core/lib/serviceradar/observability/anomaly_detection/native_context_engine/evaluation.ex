defmodule ServiceRadar.Observability.AnomalyDetection.NativeContextEngine.Evaluation do
  @moduledoc false

  alias ServiceRadar.Observability.AnomalyDetection.NativeContextEngine.BatchPreparation
  alias ServiceRadar.Observability.AnomalyDetection.NativeContextEngine.Checkpoint
  alias ServiceRadar.Observability.AnomalyDetection.NativeContextEngine.Retention
  alias ServiceRadar.Observability.AnomalyDetection.NativeContextEngine.ShardEvaluator

  @spec events([map()], map(), map()) :: {list(), map()}
  def events(samples, state, context) do
    sample_lookup = List.to_tuple(samples)

    {groups, duplicate_results, missing_results, event_entries} =
      BatchPreparation.prepare_events(
        samples,
        context.shard_count,
        context.opts,
        context.preparation
      )

    {results, error_indexes} =
      evaluate_event_groups(groups, state, missing_results, sample_lookup, context)

    BatchPreparation.mark_seen_event_entries(
      context.seen_events_table,
      event_entries,
      error_indexes
    )

    state = Checkpoint.queue_series(groups, error_indexes, state, context.seen_events_table)
    {reply(duplicate_results, results), state}
  end

  @spec events_profiled([map()], map(), map()) :: {list(), map(), map()}
  def events_profiled(samples, state, context) do
    total_started = System.monotonic_time(:nanosecond)

    {{groups, duplicate_results, missing_results, event_entries}, batch_prepare_ns} =
      timed(fn ->
        BatchPreparation.prepare_events(
          samples,
          context.shard_count,
          context.opts,
          context.preparation
        )
      end)

    {sample_lookup, sample_lookup_ns} = timed(fn -> List.to_tuple(samples) end)

    {{results, error_indexes, evaluate_profile}, _evaluate_ns} =
      timed(fn ->
        evaluate_event_groups_profiled(groups, state, missing_results, sample_lookup, context)
      end)

    {_seen_result, mark_seen_ns} =
      timed(fn ->
        BatchPreparation.mark_seen_event_entries(
          context.seen_events_table,
          event_entries,
          error_indexes
        )
      end)

    {state, checkpoint_ns} =
      timed(fn ->
        Checkpoint.queue_series(groups, error_indexes, state, context.seen_events_table)
      end)

    {reply, reassociate_ns} = timed(fn -> reply(duplicate_results, results) end)

    profile =
      Map.merge(evaluate_profile, %{
        total_ns: System.monotonic_time(:nanosecond) - total_started,
        batch_prepare_ns: batch_prepare_ns,
        dedupe_ns: batch_prepare_ns,
        mark_seen_ns: mark_seen_ns,
        prune_seen_ns: 0,
        checkpoint_ns: checkpoint_ns,
        result_reassociation_ns: reassociate_ns,
        sample_lookup_ns: sample_lookup_ns,
        input_samples: length(samples),
        candidates: BatchPreparation.event_count(groups) + length(missing_results),
        duplicate_drops: length(duplicate_results),
        emitted_results: length(results)
      })

    {reply, state, profile}
  end

  @spec compact_events([tuple()], map(), map()) :: {list(), map()}
  def compact_events(samples, state, context) do
    sample_lookup = List.to_tuple(samples)

    {groups, duplicate_results, missing_results, event_entries} =
      BatchPreparation.prepare_compact_events(
        samples,
        context.shard_count,
        context.opts,
        context.preparation
      )

    {results, error_indexes} =
      evaluate_event_groups(groups, state, missing_results, sample_lookup, context)

    BatchPreparation.mark_seen_event_entries(
      context.seen_events_table,
      event_entries,
      error_indexes
    )

    state = Checkpoint.queue_series(groups, error_indexes, state, context.seen_events_table)
    {reply(duplicate_results, results), state}
  end

  @spec compact_events_profiled([tuple()], map(), map()) :: {list(), map(), map()}
  def compact_events_profiled(samples, state, context) do
    total_started = System.monotonic_time(:nanosecond)

    {{groups, duplicate_results, missing_results, event_entries}, batch_prepare_ns} =
      timed(fn ->
        BatchPreparation.prepare_compact_events(
          samples,
          context.shard_count,
          context.opts,
          context.preparation
        )
      end)

    {sample_lookup, sample_lookup_ns} = timed(fn -> List.to_tuple(samples) end)

    {{results, error_indexes, evaluate_profile}, _evaluate_ns} =
      timed(fn ->
        evaluate_event_groups_profiled(groups, state, missing_results, sample_lookup, context)
      end)

    {_seen_result, mark_seen_ns} =
      timed(fn ->
        BatchPreparation.mark_seen_event_entries(
          context.seen_events_table,
          event_entries,
          error_indexes
        )
      end)

    {state, checkpoint_ns} =
      timed(fn ->
        Checkpoint.queue_series(groups, error_indexes, state, context.seen_events_table)
      end)

    {reply, reassociate_ns} = timed(fn -> reply(duplicate_results, results) end)

    profile =
      Map.merge(evaluate_profile, %{
        total_ns: System.monotonic_time(:nanosecond) - total_started,
        batch_prepare_ns: batch_prepare_ns,
        dedupe_ns: batch_prepare_ns,
        mark_seen_ns: mark_seen_ns,
        prune_seen_ns: 0,
        checkpoint_ns: checkpoint_ns,
        result_reassociation_ns: reassociate_ns,
        sample_lookup_ns: sample_lookup_ns,
        input_samples: length(samples),
        candidates: BatchPreparation.event_count(groups) + length(missing_results),
        duplicate_drops: length(duplicate_results),
        emitted_results: length(results)
      })

    {reply, state, profile}
  end

  defp evaluate_event_groups_profiled(groups, state, initial_results, sample_lookup, context) do
    {results, native_eval_ns} =
      timed(fn ->
        evaluate_shard_groups(groups, context.workers, context.shard_eval_timeout_ms)
      end)

    Retention.update_open_series(results, sample_lookup, context.open_series_table)

    {_eviction_result, eviction_ns} =
      timed(fn ->
        Retention.enforce_series_limit_budgeted(
          context.resources,
          state.max_series,
          state.eviction_budget,
          context.retention_tables
        )
      end)

    {{formatted, error_indexes}, result_indexing_ns} =
      timed(fn -> format_results(groups, initial_results, sample_lookup, results) end)

    {formatted, error_indexes,
     %{
       missing_split_ns: 0,
       shard_input_build_ns: 0,
       native_eval_ns: native_eval_ns,
       eviction_ns: eviction_ns,
       result_indexing_ns: result_indexing_ns,
       missing_samples: length(initial_results),
       native_results: length(results)
     }}
  end

  defp evaluate_event_groups(groups, state, initial_results, sample_lookup, context) do
    results = evaluate_shard_groups(groups, context.workers, context.shard_eval_timeout_ms)
    Retention.update_open_series(results, sample_lookup, context.open_series_table)

    Retention.enforce_series_limit_budgeted(
      context.resources,
      state.max_series,
      state.eviction_budget,
      context.retention_tables
    )

    format_results(groups, initial_results, sample_lookup, results)
  end

  defp evaluate_shard_groups(groups, workers, timeout) do
    ShardEvaluator.evaluate_groups(groups, workers, timeout)
  end

  defp format_results(groups, initial_results, sample_lookup, results) do
    error_indexes =
      Enum.reduce(results, MapSet.new(), fn
        {index, {:error, _reason}}, acc when index >= 0 -> MapSet.put(acc, index)
        {-1, {:error, _reason}}, _acc -> BatchPreparation.index_set(groups)
        _result, acc -> acc
      end)

    formatted =
      Enum.map(results, fn
        {index, result} when index >= 0 ->
          {index, sample_at!(sample_lookup, index), result}

        {_index, result} ->
          {-1, %{}, result}
      end)

    {initial_results ++ formatted,
     MapSet.union(
       error_indexes,
       MapSet.new(Enum.map(initial_results, fn {index, _sample, _result} -> index end))
     )}
  end

  defp reply(duplicate_results, results) do
    (duplicate_results ++ results)
    |> Enum.sort_by(fn {index, _sample, _result} -> index end)
    |> Enum.map(fn {_index, sample, result} -> {sample, result} end)
  end

  defp sample_at!(sample_lookup, index) when is_integer(index) and index >= 0 do
    elem(sample_lookup, index)
  end

  defp timed(fun) when is_function(fun, 0) do
    started_at = System.monotonic_time(:nanosecond)
    result = fun.()
    {result, System.monotonic_time(:nanosecond) - started_at}
  end
end
