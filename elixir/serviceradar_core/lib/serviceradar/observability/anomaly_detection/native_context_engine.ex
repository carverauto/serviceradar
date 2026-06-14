defmodule ServiceRadar.Observability.AnomalyDetection.NativeContextEngine do
  @moduledoc """
  Native shard-resource anomaly context engine.

  The GenServer owns the shard resources and serializes batch calls before they
  cross into Rust. That keeps mutable detector state inside Rust without letting
  concurrent Broadway processors contend on the same native shard resource.
  """

  use GenServer

  alias ServiceRadar.Observability.AnomalyDetection.SeriesConfig
  alias ServiceRadar.Observability.CausalReasoner

  @default_shard_count System.schedulers_online()
  @default_window_size 300
  @default_min_samples 30
  @default_n_sigma 3.0
  @default_confirm_slots 5
  @default_max_series 200_000
  @default_event_ttl_ms 3_600_000
  @default_max_seen_events 1_000_000
  @default_event_prune_interval_ms 60_000

  @resources_key {__MODULE__, :resources}
  @workers_key {__MODULE__, :workers}
  @shard_count_key {__MODULE__, :shard_count}
  @opts_key {__MODULE__, :opts}
  @seen_table __MODULE__.SeenSeries
  @seen_events_table __MODULE__.SeenEvents

  @type sample :: ServiceRadar.Observability.AnomalyDetection.SampleExtractor.sample()

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    shard_count = positive_int(Keyword.get(opts, :shard_count), @default_shard_count)

    resources =
      List.to_tuple(Enum.map(1..shard_count, fn _ -> CausalReasoner.new_shard_state() end))

    workers =
      resources
      |> Tuple.to_list()
      |> Enum.map(&start_shard_worker/1)
      |> List.to_tuple()

    reset_table(@seen_table)
    reset_table(@seen_events_table)

    :persistent_term.put(@resources_key, resources)
    :persistent_term.put(@workers_key, workers)
    :persistent_term.put(@shard_count_key, shard_count)
    :persistent_term.put(@opts_key, opts)

    {:ok,
     %{
       shard_count: shard_count,
       max_series: positive_int(Keyword.get(opts, :max_series), @default_max_series),
       event_ttl_ms: positive_int(Keyword.get(opts, :event_ttl_ms), @default_event_ttl_ms),
       max_seen_events:
         positive_int(Keyword.get(opts, :max_seen_events), @default_max_seen_events),
       event_prune_interval_ms:
         positive_int(
           Keyword.get(opts, :event_prune_interval_ms),
           @default_event_prune_interval_ms
         ),
       last_event_prune_ms: System.monotonic_time(:millisecond)
     }}
  end

  @impl true
  def terminate(_reason, _state) do
    stop_shard_workers()
    :persistent_term.erase(@resources_key)
    :persistent_term.erase(@workers_key)
    :persistent_term.erase(@shard_count_key)
    :persistent_term.erase(@opts_key)

    case :ets.whereis(@seen_table) do
      :undefined -> :ok
      table -> :ets.delete(table)
    end

    case :ets.whereis(@seen_events_table) do
      :undefined -> :ok
      table -> :ets.delete(table)
    end
  end

  @impl true
  def handle_call({:evaluate_events_batch, samples}, _from, state) do
    {reply, state} = do_evaluate_events_batch(samples, state)
    {:reply, reply, state}
  end

  def handle_call({:evaluate_events_batch_profiled, samples}, _from, state) do
    {reply, state, profile} = do_evaluate_events_batch_profiled(samples, state)
    {:reply, {reply, profile}, state}
  end

  @doc """
  Evaluates samples and returns only anomaly/clear state-change events.
  """
  @spec evaluate_events_batch([sample()]) :: [
          {sample(), {:ok, map()} | {:drop, term()} | {:error, term()}}
        ]
  def evaluate_events_batch(samples) when is_list(samples) do
    GenServer.call(__MODULE__, {:evaluate_events_batch, samples}, :infinity)
  end

  @doc false
  @spec evaluate_events_batch_profiled([sample()]) ::
          {[
             {sample(), {:ok, map()} | {:drop, term()} | {:error, term()}}
           ], map()}
  def evaluate_events_batch_profiled(samples) when is_list(samples) do
    GenServer.call(__MODULE__, {:evaluate_events_batch_profiled, samples}, :infinity)
  end

  defp do_evaluate_events_batch(samples, state) do
    {candidates, duplicate_results} =
      samples
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {sample, index}, {candidates, duplicates} ->
        key = series_key(sample)

        case event_key(sample, key) do
          nil ->
            {[{sample, index, key, nil} | candidates], duplicates}

          event_key ->
            if seen_event?(event_key) do
              {candidates, [{index, sample, {:drop, :duplicate_event}} | duplicates]}
            else
              {[{sample, index, key, event_key} | candidates], duplicates}
            end
        end
      end)

    {results, error_indexes} = evaluate_candidate_events(Enum.reverse(candidates), state)

    candidates
    |> Enum.reject(fn {_sample, index, _key, _event_key} ->
      MapSet.member?(error_indexes, index)
    end)
    |> mark_seen_events()

    state = prune_seen_events(state)

    reply =
      (duplicate_results ++ results)
      |> Enum.sort_by(fn {index, _sample, _result} -> index end)
      |> Enum.map(fn {_index, sample, result} -> {sample, result} end)

    {reply, state}
  end

  defp do_evaluate_events_batch_profiled(samples, state) do
    total_started = System.monotonic_time(:nanosecond)

    {{candidates, duplicate_results}, dedupe_ns} =
      timed(fn ->
        samples
        |> Enum.with_index()
        |> Enum.reduce({[], []}, fn {sample, index}, {candidates, duplicates} ->
          key = series_key(sample)

          case event_key(sample, key) do
            nil ->
              {[{sample, index, key, nil} | candidates], duplicates}

            event_key ->
              if seen_event?(event_key) do
                {candidates, [{index, sample, {:drop, :duplicate_event}} | duplicates]}
              else
                {[{sample, index, key, event_key} | candidates], duplicates}
              end
          end
        end)
      end)

    {{results, error_indexes, evaluate_profile}, _evaluate_ns} =
      timed(fn -> evaluate_candidate_events_profiled(Enum.reverse(candidates), state) end)

    {_seen_result, mark_seen_ns} =
      timed(fn ->
        candidates
        |> Enum.reject(fn {_sample, index, _key, _event_key} ->
          MapSet.member?(error_indexes, index)
        end)
        |> mark_seen_events()
      end)

    {state, prune_seen_ns} = timed(fn -> prune_seen_events(state) end)

    {reply, reassociate_ns} =
      timed(fn ->
        (duplicate_results ++ results)
        |> Enum.sort_by(fn {index, _sample, _result} -> index end)
        |> Enum.map(fn {_index, sample, result} -> {sample, result} end)
      end)

    profile =
      Map.merge(evaluate_profile, %{
        total_ns: System.monotonic_time(:nanosecond) - total_started,
        dedupe_ns: dedupe_ns,
        mark_seen_ns: mark_seen_ns,
        prune_seen_ns: prune_seen_ns,
        result_reassociation_ns: reassociate_ns,
        input_samples: length(samples),
        candidates: length(candidates),
        duplicate_drops: length(duplicate_results),
        emitted_results: length(results)
      })

    {reply, state, profile}
  end

  defp evaluate_candidate_events([], _state), do: {[], MapSet.new()}

  defp evaluate_candidate_events(candidates, state) do
    {missing, valid} =
      Enum.split_with(candidates, fn {_sample, _index, key, _event_key} ->
        is_nil(key)
      end)

    missing_results =
      Enum.map(missing, fn {sample, index, _key, _event_key} ->
        {index, sample, {:error, :missing_series_key}}
      end)

    do_evaluate_candidate_events(valid, state, missing_results)
  end

  defp evaluate_candidate_events_profiled([], _state) do
    {[], MapSet.new(),
     %{
       missing_split_ns: 0,
       shard_input_build_ns: 0,
       native_eval_ns: 0,
       eviction_ns: 0,
       result_indexing_ns: 0,
       missing_samples: 0,
       native_results: 0
     }}
  end

  defp evaluate_candidate_events_profiled(candidates, state) do
    {{missing, valid}, missing_split_ns} =
      timed(fn ->
        Enum.split_with(candidates, fn {_sample, _index, key, _event_key} ->
          is_nil(key)
        end)
      end)

    missing_results =
      Enum.map(missing, fn {sample, index, _key, _event_key} ->
        {index, sample, {:error, :missing_series_key}}
      end)

    {results, error_indexes, profile} =
      do_evaluate_candidate_events_profiled(valid, state, missing_results)

    {results, error_indexes,
     Map.merge(profile, %{
       missing_split_ns: missing_split_ns,
       missing_samples: length(missing)
     })}
  end

  defp do_evaluate_candidate_events_profiled([], _state, results) do
    error_indexes = MapSet.new(Enum.map(results, fn {index, _sample, _result} -> index end))

    {results, error_indexes,
     %{
       shard_input_build_ns: 0,
       native_eval_ns: 0,
       eviction_ns: 0,
       result_indexing_ns: 0,
       native_results: 0
     }}
  end

  defp do_evaluate_candidate_events_profiled(candidates, state, initial_results) do
    shard_count = current_shard_count()
    resources = current_resources()
    workers = current_workers()
    opts = current_opts()

    {{samples_by_index, groups}, shard_input_build_ns} =
      timed(fn ->
        {
          Map.new(candidates, fn {sample, index, _key, _event_key} -> {index, sample} end),
          build_shard_inputs(candidates, shard_count, opts)
        }
      end)

    {results, native_eval_ns} =
      timed(fn ->
        evaluate_shard_groups(groups, workers, shard_count)
      end)

    {_eviction_result, eviction_ns} =
      timed(fn -> enforce_series_limit(resources, state.max_series) end)

    {{formatted, error_indexes}, result_indexing_ns} =
      timed(fn ->
        error_indexes =
          Enum.reduce(results, MapSet.new(), fn
            {index, {:error, _reason}}, acc when index >= 0 -> MapSet.put(acc, index)
            {-1, {:error, _reason}}, _acc -> MapSet.new(Map.keys(samples_by_index))
            _result, acc -> acc
          end)

        formatted =
          Enum.map(results, fn
            {index, result} when index >= 0 ->
              {index, Map.fetch!(samples_by_index, index), result}

            {_index, result} ->
              {-1, %{}, result}
          end)

        {
          initial_results ++ formatted,
          MapSet.union(
            error_indexes,
            MapSet.new(Enum.map(initial_results, fn {index, _sample, _result} -> index end))
          )
        }
      end)

    {formatted, error_indexes,
     %{
       shard_input_build_ns: shard_input_build_ns,
       native_eval_ns: native_eval_ns,
       eviction_ns: eviction_ns,
       result_indexing_ns: result_indexing_ns,
       native_results: length(results)
     }}
  end

  defp do_evaluate_candidate_events([], _state, results) do
    {results, MapSet.new(Enum.map(results, fn {index, _sample, _result} -> index end))}
  end

  defp do_evaluate_candidate_events(candidates, state, initial_results) do
    shard_count = current_shard_count()
    resources = current_resources()
    workers = current_workers()
    opts = current_opts()

    samples_by_index =
      Map.new(candidates, fn {sample, index, _key, _event_key} -> {index, sample} end)

    groups = build_shard_inputs(candidates, shard_count, opts)

    results = evaluate_shard_groups(groups, workers, shard_count)

    enforce_series_limit(resources, state.max_series)

    error_indexes =
      Enum.reduce(results, MapSet.new(), fn
        {index, {:error, _reason}}, acc when index >= 0 -> MapSet.put(acc, index)
        {-1, {:error, _reason}}, _acc -> MapSet.new(Map.keys(samples_by_index))
        _result, acc -> acc
      end)

    formatted =
      Enum.map(results, fn
        {index, result} when index >= 0 ->
          {index, Map.fetch!(samples_by_index, index), result}

        {_index, result} ->
          {-1, %{}, result}
      end)

    {initial_results ++ formatted,
     MapSet.union(
       error_indexes,
       MapSet.new(Enum.map(initial_results, fn {index, _sample, _result} -> index end))
     )}
  end

  defp build_shard_inputs(candidates, shard_count, opts) do
    {_next_index, groups} =
      Enum.reduce(candidates, {0, :erlang.make_tuple(shard_count, [])}, fn {sample, index, key,
                                                                            _event_key},
                                                                           {next_index, groups} ->
        shard_index = shard_index(key, shard_count)
        input = input(sample, index, key, shard_index, opts)
        group = elem(groups, shard_index)

        {next_index + 1, put_elem(groups, shard_index, [input | group])}
      end)

    groups
  end

  defp evaluate_shard_groups(groups, workers, shard_count) do
    0..(shard_count - 1)
    |> Enum.reduce([], fn shard_index, requests ->
      case elem(groups, shard_index) do
        [] ->
          requests

        inputs ->
          ref = make_ref()
          send(elem(workers, shard_index), {:evaluate, self(), ref, Enum.reverse(inputs)})
          [ref | requests]
      end
    end)
    |> Enum.reverse()
    |> Enum.flat_map(&receive_shard_result/1)
  end

  defp receive_shard_result(ref) do
    receive do
      {^ref, results} -> results
    end
  end

  defp start_shard_worker(resource), do: spawn_link(fn -> shard_worker_loop(resource) end)

  defp shard_worker_loop(resource) do
    receive do
      {:evaluate, caller, ref, inputs} ->
        send(caller, {ref, evaluate_shard_group(resource, inputs)})
        shard_worker_loop(resource)

      :stop ->
        :ok
    end
  end

  defp evaluate_shard_group(resource, inputs) do
    CausalReasoner.reason_state_value_tuples_changes(resource, inputs)
  rescue
    reason -> [{-1, {:error, {:shard_exit, reason}}}]
  catch
    kind, reason -> [{-1, {:error, {:shard_exit, {kind, reason}}}}]
  end

  defp stop_shard_workers do
    case :persistent_term.get(@workers_key, nil) do
      nil -> :ok
      workers -> workers |> Tuple.to_list() |> Enum.each(&send(&1, :stop))
    end
  end

  defp input(sample, index, key, shard_index, opts) do
    tap(
      {index, key, maybe_context(key, sample, opts), value(sample, :value),
       value(sample, :observed_at_unix_nano)},
      fn _input -> touch_series(key, shard_index) end
    )
  end

  defp maybe_context(nil, _sample, _opts), do: nil

  defp maybe_context(key, sample, opts) do
    now = System.monotonic_time(:millisecond)

    if :ets.insert_new(@seen_table, {key, shard_index(key, current_shard_count()), now}) do
      SeriesConfig.apply_to_context(
        base_context(),
        SeriesConfig.resolve(sample, opts),
        context_overrides_from_opts(opts)
      )
    end
  end

  defp touch_series(nil, _shard_index), do: :ok

  defp touch_series(key, shard_index) do
    :ets.insert(@seen_table, {key, shard_index, System.monotonic_time(:millisecond)})
  end

  defp enforce_series_limit(_resources, max_series) when max_series <= 0, do: :ok

  defp enforce_series_limit(resources, max_series) do
    case :ets.info(@seen_table, :size) do
      size when is_integer(size) and size > max_series ->
        @seen_table
        |> :ets.tab2list()
        |> Enum.sort_by(fn {_key, _shard_index, last_seen} -> last_seen end)
        |> Enum.take(size - max_series)
        |> Enum.each(fn {key, shard_index, _last_seen} ->
          CausalReasoner.forget_series(elem(resources, shard_index), key)
          :ets.delete(@seen_table, key)
        end)

      _ ->
        :ok
    end
  end

  defp current_resources do
    :persistent_term.get(@resources_key)
  end

  defp current_workers do
    :persistent_term.get(@workers_key)
  end

  defp current_shard_count do
    :persistent_term.get(
      @shard_count_key,
      Application.get_env(
        :serviceradar_core,
        :anomaly_detection_shard_count,
        @default_shard_count
      )
    )
  end

  defp current_opts, do: :persistent_term.get(@opts_key, [])

  defp base_context do
    %{
      baseline: [],
      window_tail: [],
      rolling_acc: nil,
      min_samples: @default_min_samples,
      window_size: @default_window_size,
      n_sigma: @default_n_sigma,
      confirm_slots: @default_confirm_slots,
      consecutive_anomalous: 0
    }
  end

  defp shard_index(nil, shard_count), do: :erlang.phash2(:missing_series_key, shard_count)
  defp shard_index(series_key, shard_count), do: :erlang.phash2(series_key, shard_count)

  defp series_key(%{series_key: value}) when is_binary(value) and value != "", do: value
  defp series_key(%{"series_key" => value}) when is_binary(value) and value != "", do: value
  defp series_key(_sample), do: nil

  defp value(%{} = map, key), do: Map.get(map, key, Map.get(map, to_string(key)))
  defp value(_sample, _key), do: nil

  defp event_key(sample, series_key) do
    with key when not is_nil(key) <- event_identity(sample),
         series_key when is_binary(series_key) <- series_key do
      {series_key, key}
    else
      _ -> nil
    end
  end

  defp event_identity(%{} = sample) do
    Map.get(sample, :event_id, Map.get(sample, "event_id")) ||
      Map.get(sample, :order_key, Map.get(sample, "order_key")) ||
      observed_identity(sample)
  end

  defp event_identity(_sample), do: nil

  defp observed_identity(%{} = sample) do
    observed_at = value(sample, :observed_at_unix_nano)
    sample_value = value(sample, :value)

    if is_nil(observed_at), do: nil, else: {:observed_at, observed_at, sample_value}
  end

  defp seen_event?(nil), do: false
  defp seen_event?(key), do: :ets.member(@seen_events_table, key)

  defp timed(fun) when is_function(fun, 0) do
    started_at = System.monotonic_time(:nanosecond)
    result = fun.()
    {result, System.monotonic_time(:nanosecond) - started_at}
  end

  defp mark_seen_events(candidates) do
    now = System.monotonic_time(:millisecond)

    entries =
      Enum.reduce(candidates, [], fn
        {_sample, _index, _series_key, nil}, acc -> acc
        {_sample, _index, _series_key, event_key}, acc -> [{event_key, now} | acc]
      end)

    case entries do
      [] -> :ok
      entries -> :ets.insert(@seen_events_table, entries)
    end
  end

  defp prune_seen_events(
         %{
           event_ttl_ms: ttl_ms,
           max_seen_events: max_seen_events,
           event_prune_interval_ms: prune_interval_ms,
           last_event_prune_ms: last_prune_ms
         } = state
       ) do
    now = System.monotonic_time(:millisecond)
    size = :ets.info(@seen_events_table, :size)
    over_limit? = is_integer(size) and size > max_seen_events
    ttl_due? = ttl_ms > 0 and now - last_prune_ms >= prune_interval_ms

    if over_limit? or ttl_due? do
      @seen_events_table
      |> :ets.tab2list()
      |> Enum.reject(fn {_key, seen_at} -> ttl_ms > 0 and now - seen_at <= ttl_ms end)
      |> Enum.each(fn {key, _seen_at} -> :ets.delete(@seen_events_table, key) end)

      case :ets.info(@seen_events_table, :size) do
        size when is_integer(size) and size > max_seen_events ->
          @seen_events_table
          |> :ets.tab2list()
          |> Enum.sort_by(fn {_key, seen_at} -> seen_at end)
          |> Enum.take(size - max_seen_events)
          |> Enum.each(fn {key, _seen_at} -> :ets.delete(@seen_events_table, key) end)

        _ ->
          :ok
      end

      %{state | last_event_prune_ms: now}
    else
      state
    end
  end

  defp positive_int(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, fallback), do: fallback

  defp reset_table(table_name) do
    case :ets.whereis(table_name) do
      :undefined -> :ok
      table -> :ets.delete(table)
    end

    :ets.new(table_name, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])
  end

  defp context_overrides_from_opts(opts) do
    opts
    |> Keyword.take([
      :rolling_enabled,
      :seasonal_enabled,
      :trend_enabled,
      :min_samples,
      :seasonal_min_samples,
      :trend_min_samples,
      :window_size,
      :n_sigma,
      :seasonal_n_sigma,
      :trend_n_sigma,
      :confirm_slots,
      :seasonal_sensitivity
    ])
    |> Map.new()
  end
end
