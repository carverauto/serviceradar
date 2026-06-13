defmodule ServiceRadar.Observability.AnomalyDetection.ShardedContextEngine do
  @moduledoc """
  Shard-owned anomaly context engine for high-cardinality batch evaluation.

  Each shard owns many series contexts in one GenServer. A Broadway message can
  hand the engine a batch of samples; samples are routed to shards by series key,
  then each shard evaluates one in-order sample per series with
  `CausalReasoner.reason_batch/1`. This removes the per-series GenServer
  bottleneck while preserving single-writer state for every series.
  """

  use Supervisor

  alias ServiceRadar.Observability.AnomalyDetection.ShardedContextEngine.Shard

  @default_shard_count System.schedulers_online()
  @shard_count_key {__MODULE__, :shard_count}

  @type sample :: ServiceRadar.Observability.AnomalyDetection.SampleExtractor.sample()

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    shard_count = shard_count(opts)
    :persistent_term.put(@shard_count_key, shard_count)

    children =
      Enum.map(0..(shard_count - 1), fn shard_index ->
        Supervisor.child_spec(
          {Shard, Keyword.merge(opts, shard_index: shard_index, shard_count: shard_count)},
          id: {Shard, shard_index}
        )
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Evaluates one sample through the owning shard.
  """
  @spec evaluate(sample()) :: {:ok, map()} | {:drop, term()} | {:error, term()}
  def evaluate(sample) do
    case evaluate_batch([sample]) do
      [result] -> result
      [] -> {:drop, :no_scalar_samples}
    end
  end

  @doc """
  Evaluates samples in input order across shard-owned state.
  """
  @spec evaluate_batch([sample()]) :: [{:ok, map()} | {:drop, term()} | {:error, term()}]
  def evaluate_batch(samples) when is_list(samples) do
    shard_count = current_shard_count()

    samples
    |> Enum.with_index()
    |> Enum.group_by(fn {sample, _index} ->
      sample |> series_key() |> shard_index(shard_count)
    end)
    |> send_shard_requests()
    |> Enum.flat_map(fn
      {:reply, results} -> results
      {:error, reason} -> [{-1, {:error, {:shard_exit, reason}}}]
      :timeout -> [{-1, {:error, :shard_timeout}}]
    end)
    |> reorder_results(length(samples))
  end

  @doc """
  Evaluates samples and returns only anomaly/clear state-change events.
  """
  @spec evaluate_events_batch([sample()]) :: [
          {sample(), {:ok, map()} | {:drop, term()} | {:error, term()}}
        ]
  def evaluate_events_batch(samples) when is_list(samples) do
    shard_count = current_shard_count()
    samples_tuple = List.to_tuple(samples)

    samples
    |> Enum.with_index()
    |> Enum.group_by(fn {sample, _index} ->
      sample |> series_key() |> shard_index(shard_count)
    end)
    |> send_shard_change_requests()
    |> Enum.flat_map(fn
      {:reply, results} -> results
      {:error, reason} -> [{-1, {:error, {:shard_exit, reason}}}]
      :timeout -> [{-1, {:error, :shard_timeout}}]
    end)
    |> Enum.sort_by(fn {index, _result} -> index end)
    |> Enum.map(fn
      {index, result} when index >= 0 -> {elem(samples_tuple, index), result}
      {_index, result} -> {%{}, result}
    end)
  end

  @doc false
  @spec shard_name(non_neg_integer()) :: atom()
  def shard_name(shard_index), do: Module.concat(__MODULE__, "Shard#{shard_index}")

  defp reorder_results(results, count) do
    by_index = Map.new(results)

    Enum.map(0..(count - 1)//1, fn index ->
      Map.get(by_index, index, {:error, :missing_shard_result})
    end)
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

  defp shard_count(opts) do
    opts
    |> Keyword.get(
      :shard_count,
      Application.get_env(
        :serviceradar_core,
        :anomaly_detection_shard_count,
        @default_shard_count
      )
    )
    |> positive_int(@default_shard_count)
  end

  defp shard_index(nil, shard_count), do: :erlang.phash2(:missing_series_key, shard_count)
  defp shard_index(series_key, shard_count), do: :erlang.phash2(series_key, shard_count)

  defp send_shard_requests(grouped_samples) do
    grouped_samples
    |> Enum.map(fn {shard_index, indexed_samples} ->
      shard_index
      |> shard_name()
      |> :gen_server.send_request({:evaluate_batch, indexed_samples})
    end)
    |> Enum.map(&:gen_server.wait_response(&1, :infinity))
  end

  defp send_shard_change_requests(grouped_samples) do
    grouped_samples
    |> Enum.map(fn {shard_index, indexed_samples} ->
      shard_index
      |> shard_name()
      |> :gen_server.send_request({:evaluate_changes_batch, indexed_samples})
    end)
    |> Enum.map(&:gen_server.wait_response(&1, :infinity))
  end

  defp series_key(%{series_key: value}) when is_binary(value) and value != "", do: value
  defp series_key(%{"series_key" => value}) when is_binary(value) and value != "", do: value
  defp series_key(_sample), do: nil

  defp positive_int(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, fallback), do: fallback
end

defmodule ServiceRadar.Observability.AnomalyDetection.ShardedContextEngine.Shard do
  @moduledoc false

  use GenServer

  alias ServiceRadar.Observability.AnomalyDetection.SeriesConfig
  alias ServiceRadar.Observability.CausalReasoner

  @default_max_series 200_000
  @default_window_size 300
  @default_min_samples 30
  @default_n_sigma 3.0
  @default_confirm_slots 5
  @default_max_events 600

  defstruct [
    :shard_index,
    :reasoner,
    :native_state,
    :series_config_resolver,
    :series_config_opts,
    :context_overrides,
    :max_series,
    series: %{}
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    shard_index = Keyword.fetch!(opts, :shard_index)

    GenServer.start_link(__MODULE__, opts,
      name:
        ServiceRadar.Observability.AnomalyDetection.ShardedContextEngine.shard_name(shard_index)
    )
  end

  @spec evaluate_batch(GenServer.name(), [{map(), non_neg_integer()}]) :: [
          {non_neg_integer(), {:ok, map()} | {:drop, term()} | {:error, term()}}
        ]
  def evaluate_batch(shard, indexed_samples) do
    GenServer.call(shard, {:evaluate_batch, indexed_samples}, :infinity)
  end

  @spec evaluate_changes_batch(GenServer.name(), [{map(), non_neg_integer()}]) :: [
          {non_neg_integer(), {:ok, map()} | {:drop, term()} | {:error, term()}}
        ]
  def evaluate_changes_batch(shard, indexed_samples) do
    GenServer.call(shard, {:evaluate_changes_batch, indexed_samples}, :infinity)
  end

  @impl true
  def init(opts) do
    reasoner = Keyword.get(opts, :reasoner, reasoner())

    {:ok,
     %__MODULE__{
       shard_index: Keyword.fetch!(opts, :shard_index),
       reasoner: reasoner,
       native_state: new_native_state(reasoner),
       series_config_resolver: Keyword.get(opts, :series_config_resolver, SeriesConfig),
       series_config_opts: Keyword.get(opts, :series_config_opts, []),
       context_overrides: context_overrides_from_opts(opts),
       max_series: Keyword.get(opts, :max_series, @default_max_series)
     }}
  end

  @impl true
  def handle_call({:evaluate_batch, indexed_samples}, _from, state) do
    {state, results} = evaluate_ordered_batch(state, indexed_samples)
    {:reply, results, state}
  end

  @impl true
  def handle_call({:evaluate_changes_batch, indexed_samples}, _from, state) do
    {state, results} = evaluate_ordered_changes_batch(state, indexed_samples)
    {:reply, results, state}
  end

  defp evaluate_ordered_batch(state, indexed_samples) do
    {missing, valid} =
      Enum.split_with(indexed_samples, fn {sample, _index} -> missing_series_key?(sample) end)

    missing_results =
      Enum.map(missing, fn {_sample, index} -> {index, {:error, :missing_series_key}} end)

    do_evaluate_ordered_batch(valid, state, missing_results)
  end

  defp evaluate_ordered_changes_batch(%{native_state: native_state} = state, indexed_samples)
       when not is_nil(native_state) do
    {missing, valid} =
      Enum.split_with(indexed_samples, fn {sample, _index} -> missing_series_key?(sample) end)

    missing_results =
      Enum.map(missing, fn {_sample, index} -> {index, {:error, :missing_series_key}} end)

    {state, change_results} = evaluate_native_changes_batch(state, valid)
    {state, missing_results ++ change_results}
  end

  defp evaluate_ordered_changes_batch(state, indexed_samples) do
    evaluate_ordered_batch(state, indexed_samples)
  end

  defp do_evaluate_ordered_batch([], state, results), do: {state, results}

  defp do_evaluate_ordered_batch(queue, %{native_state: native_state} = state, results)
       when not is_nil(native_state) do
    {state, batch_results} = evaluate_native_batch(state, queue)
    {state, results ++ Enum.reverse(batch_results)}
  end

  defp do_evaluate_ordered_batch(queue, state, results) do
    {batch, rest} = take_one_per_series(queue)
    {state, batch_results} = evaluate_independent_batch(state, batch)
    do_evaluate_ordered_batch(rest, state, results ++ Enum.reverse(batch_results))
  end

  defp evaluate_native_batch(state, batch) do
    {inputs, series_states} =
      Enum.map_reduce(batch, state.series, fn {sample, _index}, series_states ->
        key = series_key(sample)
        series_state = Map.get_lazy(series_states, key, fn -> new_series_state(state, sample) end)

        {
          %{
            series_key: key,
            context: series_state.context,
            sample: reason_sample(sample)
          },
          Map.put(series_states, key, series_state)
        }
      end)

    results = reason_state_batch(state, inputs)

    state = enforce_series_limit(%{state | series: series_states})

    batch
    |> Enum.zip(results)
    |> Enum.reduce({state, []}, fn
      {{_sample, index}, {:ok, verdict}}, {state, results} ->
        {state, [{index, {:ok, verdict}} | results]}

      {{_sample, index}, {:error, reason}}, {state, results} ->
        {state, [{index, {:error, reason}} | results]}
    end)
  end

  defp evaluate_native_changes_batch(state, batch) do
    {inputs, duplicate_results, series_states, candidates} =
      Enum.reduce(batch, {[], [], state.series, []}, fn {sample, index},
                                                        {inputs, duplicates, series_states,
                                                         candidates} ->
        key = series_key(sample)
        existing? = Map.has_key?(series_states, key)
        series_state = Map.get_lazy(series_states, key, fn -> new_series_state(state, sample) end)

        case event_identity(sample) do
          event_key when not is_nil(event_key) ->
            if event_seen?(series_state, event_key) do
              {inputs, [{index, {:drop, :duplicate_event}} | duplicates], series_states,
               candidates}
            else
              input = native_value_input(sample, index, key, existing?, series_state)

              {
                [input | inputs],
                duplicates,
                Map.put(series_states, key, series_state),
                [{key, event_key, index} | candidates]
              }
            end

          nil ->
            input = native_value_input(sample, index, key, existing?, series_state)

            {
              [input | inputs],
              duplicates,
              Map.put(series_states, key, series_state),
              [{key, nil, index} | candidates]
            }
        end
      end)

    results = reason_state_value_changes(state, Enum.reverse(inputs))
    error_indexes = error_indexes(results)

    series_states =
      Enum.reduce(candidates, series_states, fn
        {_key, nil, _index}, series_states ->
          series_states

        {key, event_key, index}, series_states ->
          if MapSet.member?(error_indexes, index) do
            series_states
          else
            Map.update!(series_states, key, &remember_event(&1, event_key))
          end
      end)

    state = enforce_series_limit(%{state | series: series_states})

    {state, Enum.reverse(duplicate_results, results)}
  end

  defp native_value_input(sample, index, key, existing?, series_state) do
    %{
      index: index,
      series_key: key,
      context: if(existing?, do: nil, else: series_state.context),
      value: Map.get(sample, :value, Map.get(sample, "value")),
      observed_at_unix_nano:
        Map.get(sample, :observed_at_unix_nano, Map.get(sample, "observed_at_unix_nano"))
    }
  end

  defp error_indexes(results) do
    Enum.reduce(results, MapSet.new(), fn
      {index, {:error, _reason}}, acc -> MapSet.put(acc, index)
      _result, acc -> acc
    end)
  end

  defp take_one_per_series(queue) do
    {batch, rest, _seen} =
      Enum.reduce(queue, {[], [], MapSet.new()}, fn {sample, index}, {batch, rest, seen} ->
        key = series_key(sample)

        if MapSet.member?(seen, key) do
          {batch, [{sample, index} | rest], seen}
        else
          {[{sample, index} | batch], rest, MapSet.put(seen, key)}
        end
      end)

    {Enum.reverse(batch), Enum.reverse(rest)}
  end

  defp evaluate_independent_batch(state, batch) do
    {inputs, series_states} =
      Enum.map_reduce(batch, state.series, fn {sample, _index}, series_states ->
        key = series_key(sample)
        series_state = Map.get_lazy(series_states, key, fn -> new_series_state(state, sample) end)
        {{series_state.context, reason_sample(sample)}, Map.put(series_states, key, series_state)}
      end)

    results = reason_batch(state.reasoner, inputs)

    batch
    |> Enum.zip(results)
    |> Enum.reduce({%{state | series: series_states}, []}, fn
      {{sample, index}, {:ok, verdict}}, {state, results} ->
        key = series_key(sample)

        series_state =
          state.series
          |> Map.fetch!(key)
          |> fold_series_state(sample, verdict)

        state = put_series_state(state, key, series_state)
        {state, [{index, {:ok, verdict}} | results]}

      {{_sample, index}, {:error, reason}}, {state, results} ->
        {state, [{index, {:error, reason}} | results]}
    end)
  end

  defp reason_batch(reasoner, inputs) do
    if function_exported?(reasoner, :reason_batch, 1) do
      reasoner.reason_batch(inputs)
    else
      Enum.map(inputs, fn {context, sample} -> reasoner.reason(context, sample) end)
    end
  end

  defp reason_state_batch(state, inputs) do
    if function_exported?(state.reasoner, :reason_state_batch_events, 2) do
      state.reasoner.reason_state_batch_events(state.native_state, inputs)
    else
      state.reasoner.reason_state_batch(state.native_state, inputs)
    end
  end

  defp reason_state_value_changes(state, inputs) do
    if function_exported?(state.reasoner, :reason_state_values_changes, 2) do
      state.reasoner.reason_state_values_changes(state.native_state, inputs)
    else
      state.reasoner.reason_state_batch_changes(
        state.native_state,
        Enum.map(inputs, fn input ->
          %{
            index: input.index,
            series_key: input.series_key,
            context: input.context || %{},
            sample: %{
              value: input.value,
              observed_at_unix_nano: input.observed_at_unix_nano
            }
          }
        end)
      )
    end
  end

  defp put_series_state(state, key, series_state) do
    enforce_series_limit(%{state | series: Map.put(state.series, key, series_state)})
  end

  defp enforce_series_limit(state) do
    series = state.series

    if map_size(series) > state.max_series do
      [evicted | keys] = Map.keys(series)
      forget_native_series(state, evicted)

      %{state | series: Map.take(series, keys)}
    else
      state
    end
  end

  defp forget_native_series(%{native_state: nil}, _key), do: :ok

  defp forget_native_series(state, key) do
    if function_exported?(state.reasoner, :forget_series, 2) do
      state.reasoner.forget_series(state.native_state, key)
    end

    :ok
  end

  defp new_series_state(state, sample) do
    context =
      SeriesConfig.apply_to_context(
        base_context(),
        state.series_config_resolver.resolve(sample, state.series_config_opts),
        state.context_overrides
      )

    %{context: context, event_ids: MapSet.new(), event_order: []}
  end

  defp event_seen?(%{event_ids: event_ids}, event_key), do: MapSet.member?(event_ids, event_key)
  defp event_seen?(_series_state, _event_key), do: false

  defp remember_event(series_state, event_key) do
    event_ids = Map.get(series_state, :event_ids, MapSet.new())
    event_order = Map.get(series_state, :event_order, [])

    if MapSet.member?(event_ids, event_key) do
      series_state
    else
      ordered = [event_key | event_order]
      {kept, dropped} = Enum.split(ordered, @default_max_events)

      %{
        series_state
        | event_ids:
            Enum.reduce(dropped, MapSet.put(event_ids, event_key), &MapSet.delete(&2, &1)),
          event_order: kept
      }
    end
  end

  defp fold_series_state(series_state, sample, verdict) do
    context = series_state.context
    window_tail = next_window_tail(context, sample, verdict)

    %{
      series_state
      | context: %{
          context
          | baseline: [],
            window_tail: window_tail,
            rolling_acc: next_rolling_acc(verdict, context),
            consecutive_anomalous:
              Map.get(
                verdict,
                :next_consecutive_anomalous,
                Map.get(verdict, "next_consecutive_anomalous", 0)
              )
        }
    }
  end

  defp next_window_tail(context, sample, verdict) do
    current_tail = context[:window_tail] || context.baseline

    case verdict_value(verdict, :next_window_tail) do
      tail when is_list(tail) ->
        tail
        |> numeric_list(current_tail)
        |> Enum.take(-context.window_size)

      _ ->
        if include_in_baseline?(verdict) do
          current_tail
          |> Kernel.++([sample.value])
          |> Enum.take(-context.window_size)
        else
          current_tail
        end
    end
  end

  defp next_rolling_acc(verdict, context) do
    verdict
    |> verdict_value(:next_rolling_acc)
    |> normalize_rolling_acc(context[:rolling_acc])
  end

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

  defp reason_sample(sample) do
    %{
      value: Map.get(sample, :value, Map.get(sample, "value")),
      observed_at_unix_nano:
        Map.get(sample, :observed_at_unix_nano, Map.get(sample, "observed_at_unix_nano"))
    }
  end

  defp event_identity(%{} = sample) do
    Map.get(sample, :event_id, Map.get(sample, "event_id")) ||
      Map.get(sample, :order_key, Map.get(sample, "order_key")) ||
      observed_identity(sample)
  end

  defp event_identity(_sample), do: nil

  defp observed_identity(%{} = sample) do
    observed_at =
      Map.get(sample, :observed_at_unix_nano, Map.get(sample, "observed_at_unix_nano"))

    sample_value = Map.get(sample, :value, Map.get(sample, "value"))

    if is_nil(observed_at), do: nil, else: {:observed_at, observed_at, sample_value}
  end

  defp missing_series_key?(sample), do: is_nil(series_key(sample))

  defp series_key(%{series_key: value}) when is_binary(value) and value != "", do: value
  defp series_key(%{"series_key" => value}) when is_binary(value) and value != "", do: value
  defp series_key(_sample), do: nil

  defp verdict_value(nil, _key), do: nil

  defp verdict_value(verdict, key) when is_map(verdict),
    do: Map.get(verdict, key, Map.get(verdict, to_string(key)))

  defp include_in_baseline?(nil), do: false

  defp include_in_baseline?(verdict) do
    Map.get(verdict, :include_in_baseline, Map.get(verdict, "include_in_baseline", true))
  end

  defp numeric_list(values, _fallback) when is_list(values), do: Enum.filter(values, &is_number/1)
  defp numeric_list(_values, fallback), do: fallback

  defp normalize_rolling_acc(%{} = acc, fallback) do
    count = Map.get(acc, :count, Map.get(acc, "count"))
    mean = Map.get(acc, :mean, Map.get(acc, "mean"))
    m2 = Map.get(acc, :m2, Map.get(acc, "m2"))

    if is_integer(count) and count >= 0 and is_number(mean) and is_number(m2) and m2 >= 0.0 do
      %{count: count, mean: mean * 1.0, m2: m2 * 1.0}
    else
      fallback
    end
  end

  defp normalize_rolling_acc(_acc, fallback), do: fallback

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

  defp reasoner do
    Application.get_env(:serviceradar_core, :anomaly_detection_reasoner, CausalReasoner)
  end

  defp new_native_state(reasoner) do
    if function_exported?(reasoner, :new_shard_state, 0) and
         function_exported?(reasoner, :reason_state_batch, 2) do
      reasoner.new_shard_state()
    end
  end
end
