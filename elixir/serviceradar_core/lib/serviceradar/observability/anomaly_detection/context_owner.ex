defmodule ServiceRadar.Observability.AnomalyDetection.ContextOwner do
  @moduledoc """
  Single-writer per-series anomaly context owner.

  The owner keeps a bounded ordered log of samples and rebuilds context from
  that log when late samples arrive. Rebuilding is deliberate: it makes the
  fold deterministic for out-of-order delivery and lets duplicate event IDs be
  ignored without mutating the baseline twice.
  """

  use GenServer

  alias ServiceRadar.Observability.AnomalyDetection.ContextEngine
  alias ServiceRadar.Observability.CausalReasoner

  @default_max_events 600
  @default_window_size 300
  @default_min_samples 30
  @default_n_sigma 3.0
  @default_confirm_slots 5

  defstruct [
    :series_key,
    :max_events,
    :reasoner,
    updates: [],
    verdicts: %{},
    context: %{
      baseline: [],
      min_samples: @default_min_samples,
      window_size: @default_window_size,
      n_sigma: @default_n_sigma,
      confirm_slots: @default_confirm_slots,
      consecutive_anomalous: 0
    }
  ]

  @type sample :: ServiceRadar.Observability.AnomalyDetection.SampleExtractor.sample()

  @doc false
  def child_spec(opts) do
    series_key = Keyword.fetch!(opts, :series_key)

    %{
      id: {__MODULE__, series_key},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    series_key = Keyword.fetch!(opts, :series_key)
    name = Keyword.get(opts, :name, ContextEngine.via(series_key))

    if is_nil(name) do
      GenServer.start_link(__MODULE__, opts)
    else
      GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec evaluate(pid() | GenServer.name(), sample()) ::
          {:ok, map()} | {:drop, term()} | {:error, term()}
  def evaluate(owner, sample) do
    GenServer.call(owner, {:evaluate, sample})
  end

  @doc false
  @spec snapshot(pid() | GenServer.name()) :: map()
  def snapshot(owner), do: GenServer.call(owner, :snapshot)

  @impl true
  def init(opts) do
    series_key = Keyword.fetch!(opts, :series_key)

    {:ok,
     %__MODULE__{
       series_key: series_key,
       max_events: Keyword.get(opts, :max_events, @default_max_events),
       reasoner: Keyword.get(opts, :reasoner, reasoner())
     }}
  end

  @impl true
  def handle_call({:evaluate, sample}, _from, state) do
    update = normalize_update(sample)

    cond do
      Map.has_key?(state.verdicts, update.event_id) ->
        {:reply, {:ok, state.verdicts[update.event_id]}, state}

      append_update?(state.updates, update) ->
        {state, verdict} = append_and_fold(state, update)
        {:reply, {:ok, verdict}, state}

      true ->
        case put_update(state, update) do
          {:ok, state} ->
            state = rebuild(state)
            {:reply, {:ok, state.verdicts[update.event_id]}, state}

          {:drop, reason} ->
            {:reply, {:drop, reason}, state}
        end
    end
  rescue
    error ->
      {:reply, {:error, error}, state}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       series_key: state.series_key,
       update_count: length(state.updates),
       event_ids: Enum.map(state.updates, & &1.event_id),
       context: state.context,
       verdicts: state.verdicts
     }, state}
  end

  defp put_update(state, update) do
    {updates, _dropped} =
      [update | state.updates]
      |> Enum.uniq_by(& &1.event_id)
      |> Enum.sort_by(& &1.order_key)
      |> trim_updates(state.max_events)

    if Enum.any?(updates, &(&1.event_id == update.event_id)) do
      {:ok, %{state | updates: updates}}
    else
      {:drop, :outside_window}
    end
  end

  defp append_and_fold(state, update) do
    {updates, dropped} = trim_updates(state.updates ++ [update], state.max_events)
    context = remove_dropped_from_context(state.context, dropped, state.verdicts)
    {context, verdict} = reason_update(state.reasoner, context, update)

    verdicts =
      state.verdicts
      |> Map.drop(Enum.map(dropped, & &1.event_id))
      |> Map.put(update.event_id, verdict)

    {%{state | updates: updates, context: context, verdicts: verdicts}, verdict}
  end

  defp rebuild(state) do
    {context, verdicts} =
      Enum.reduce(state.updates, {initial_context(), %{}}, fn update, {context, verdicts} ->
        {context, verdict} = reason_update(state.reasoner, context, update)
        {context, Map.put(verdicts, update.event_id, verdict)}
      end)

    %{state | context: context, verdicts: verdicts}
  end

  defp reason_update(reasoner, context, update) do
    sample = update.sample

    case reasoner.reason(context, %{
           value: sample.value,
           observed_at_unix_nano: sample.observed_at_unix_nano
         }) do
      {:ok, verdict} ->
        {fold_context(context, sample, verdict), verdict}

      {:error, reason} ->
        {context, %{state: "error", anomalous: false, reason: inspect(reason)}}
    end
  end

  defp append_update?([], _update), do: true

  defp append_update?(updates, update) do
    tail = List.last(updates)
    update.order_key >= tail.order_key
  end

  defp remove_dropped_from_context(context, dropped, verdicts) do
    Enum.reduce(dropped, context, fn update, context ->
      if include_in_baseline?(Map.get(verdicts, update.event_id)) do
        remove_baseline_value(context, update.sample.value)
      else
        context
      end
    end)
  end

  defp remove_baseline_value(context, value) do
    case Enum.split_while(context.baseline, &(&1 != value)) do
      {_prefix, []} -> context
      {prefix, [_value | suffix]} -> %{context | baseline: prefix ++ suffix}
    end
  end

  defp fold_context(context, sample, verdict) do
    baseline =
      if include_in_baseline?(verdict) do
        context.baseline
        |> Kernel.++([sample.value])
        |> Enum.take(-context.window_size)
      else
        context.baseline
      end

    %{
      context
      | baseline: baseline,
        consecutive_anomalous:
          Map.get(
            verdict,
            :next_consecutive_anomalous,
            Map.get(verdict, "next_consecutive_anomalous", 0)
          )
    }
  end

  defp include_in_baseline?(nil), do: false

  defp include_in_baseline?(verdict) do
    Map.get(verdict, :include_in_baseline, Map.get(verdict, "include_in_baseline", true))
  end

  defp initial_context do
    %{
      baseline: [],
      min_samples: @default_min_samples,
      window_size: @default_window_size,
      n_sigma: @default_n_sigma,
      confirm_slots: @default_confirm_slots,
      consecutive_anomalous: 0
    }
  end

  defp normalize_update(sample) do
    sample = Map.new(sample)
    event_id = Map.get(sample, :event_id) || fallback_event_id(sample)

    %{
      event_id: event_id,
      order_key: normalize_order_key(Map.get(sample, :order_key), sample, event_id),
      sample: sample
    }
  end

  defp normalize_order_key({timestamp, key, sample_timestamp, sample_key}, _sample, _event_id)
       when is_integer(timestamp) and is_binary(key) and is_integer(sample_timestamp) and
              is_binary(sample_key),
       do: {timestamp, key, sample_timestamp, sample_key}

  defp normalize_order_key({timestamp, key}, sample, event_id) when is_integer(timestamp) do
    {timestamp, to_string(key), Map.get(sample, :observed_at_unix_nano) || 0, event_id}
  end

  defp normalize_order_key(key, sample, event_id) when is_binary(key) do
    timestamp = order_timestamp(sample)
    {timestamp, key, Map.get(sample, :observed_at_unix_nano) || 0, event_id}
  end

  defp normalize_order_key(nil, sample, event_id), do: fallback_order_key(sample, event_id)

  defp normalize_order_key(key, sample, event_id) do
    timestamp = order_timestamp(sample)
    {timestamp, inspect(key), Map.get(sample, :observed_at_unix_nano) || 0, event_id}
  end

  defp fallback_event_id(sample) do
    stable =
      Enum.map_join(
        [
          Map.get(sample, :series_key),
          Map.get(sample, :observed_at_unix_nano),
          Map.get(sample, :subject),
          Map.get(sample, :value)
        ],
        "|",
        &to_string/1
      )

    :sha256 |> :crypto.hash(stable) |> Base.encode16(case: :lower)
  end

  defp fallback_order_key(sample, event_id) do
    timestamp = order_timestamp(sample)
    {timestamp, event_id, Map.get(sample, :observed_at_unix_nano) || 0, event_id}
  end

  defp order_timestamp(sample) do
    metadata_value(sample, :ingress_timestamp_unix_nano) ||
      Map.get(sample, :observed_at_unix_nano) ||
      0
  end

  defp metadata_value(sample, key) do
    case Map.get(sample, :metadata) do
      metadata when is_map(metadata) ->
        Map.get(metadata, key) || Map.get(metadata, to_string(key))

      _ ->
        nil
    end
  end

  defp trim_updates(updates, max_events) when length(updates) > max_events do
    keep = Enum.take(updates, -max_events)
    drop_count = length(updates) - length(keep)
    {keep, Enum.take(updates, drop_count)}
  end

  defp trim_updates(updates, _max_events), do: {updates, []}

  defp reasoner do
    Application.get_env(:serviceradar_core, :anomaly_detection_reasoner, CausalReasoner)
  end
end
