defmodule ServiceRadar.Observability.AnomalyDetection.ContextOwner do
  @moduledoc """
  Single-writer per-series anomaly context owner.

  The owner keeps a bounded ordered log of samples and rebuilds context from
  that log when late samples arrive. Rebuilding is deliberate: it makes the
  fold deterministic for out-of-order delivery and lets duplicate event IDs be
  ignored without mutating the baseline twice.
  """

  use GenServer

  alias ServiceRadar.Observability.AnomalyDetection.BaselineSeeder
  alias ServiceRadar.Observability.AnomalyDetection.ContextCheckpoint
  alias ServiceRadar.Observability.AnomalyDetection.ContextEngine
  alias ServiceRadar.Observability.AnomalyDetection.SeriesConfig
  alias ServiceRadar.Observability.CausalReasoner

  require Logger

  @default_max_events 600
  @default_window_size 300
  @default_min_samples 30
  @default_n_sigma 3.0
  @default_confirm_slots 5

  defstruct [
    :series_key,
    :max_events,
    :reasoner,
    :checkpoint_store,
    :checkpoint_opts,
    :baseline_seeder,
    :baseline_seed_opts,
    :series_config_resolver,
    :series_config_opts,
    :context_overrides,
    :suppress_until_warmed?,
    checkpoint_restored?: false,
    series_config_applied?: false,
    live_update_count: 0,
    updates: [],
    verdicts: %{},
    base_context: %{
      baseline: [],
      min_samples: @default_min_samples,
      window_size: @default_window_size,
      n_sigma: @default_n_sigma,
      confirm_slots: @default_confirm_slots,
      consecutive_anomalous: 0
    },
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
    context = context_from_opts(opts)

    state = %__MODULE__{
      series_key: series_key,
      max_events: Keyword.get(opts, :max_events, @default_max_events),
      reasoner: Keyword.get(opts, :reasoner, reasoner()),
      checkpoint_store: Keyword.get(opts, :checkpoint_store, ContextCheckpoint),
      checkpoint_opts: Keyword.get(opts, :checkpoint_opts, []),
      baseline_seeder: Keyword.get(opts, :baseline_seeder, BaselineSeeder),
      baseline_seed_opts: Keyword.get(opts, :baseline_seed_opts, []),
      series_config_resolver: Keyword.get(opts, :series_config_resolver, SeriesConfig),
      series_config_opts: Keyword.get(opts, :series_config_opts, []),
      context_overrides: context_overrides_from_opts(opts),
      suppress_until_warmed?: Keyword.get(opts, :suppress_until_warmed?, true),
      base_context: context,
      context: context
    }

    {:ok, load_checkpoint(state)}
  end

  @impl true
  def handle_call({:evaluate, sample}, _from, state) do
    update = normalize_update(sample)

    cond do
      Map.has_key?(state.verdicts, update.event_id) ->
        {:reply, {:ok, state.verdicts[update.event_id]}, state}

      append_update?(state.updates, update) ->
        state =
          state
          |> apply_series_config(sample)
          |> seed_baseline(sample)
          |> append_and_fold(update)
          |> maybe_suppress_verdict(update.event_id)
          |> save_checkpoint()

        {:reply, {:ok, state.verdicts[update.event_id]}, state}

      true ->
        case state
             |> apply_series_config(sample)
             |> seed_baseline(sample)
             |> put_update(update) do
          {:ok, state} ->
            state =
              state
              |> rebuild_from(update.event_id)
              |> maybe_suppress_verdict(update.event_id)
              |> save_checkpoint()

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
       checkpoint_restored?: state.checkpoint_restored?,
       series_config_applied?: state.series_config_applied?,
       live_update_count: state.live_update_count,
       base_context: state.base_context,
       context: state.context,
       verdicts: state.verdicts
     }, state}
  end

  defp put_update(state, update) do
    existing? = Enum.any?(state.updates, &(&1.event_id == update.event_id))

    {updates, _dropped} =
      [update | state.updates]
      |> Enum.uniq_by(& &1.event_id)
      |> Enum.sort_by(& &1.order_key)
      |> trim_updates(state.max_events)

    if Enum.any?(updates, &(&1.event_id == update.event_id)) do
      {:ok, %{state | updates: updates, live_update_count: live_update_count(state, existing?)}}
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

    %{
      state
      | updates: updates,
        context: context,
        verdicts: verdicts,
        live_update_count: live_update_count(state, false)
    }
  end

  defp live_update_count(state, existing?) do
    if existing? or state.checkpoint_restored? do
      state.live_update_count
    else
      state.live_update_count + 1
    end
  end

  defp rebuild(state) do
    {context, verdicts} =
      Enum.reduce(state.updates, {state.base_context, %{}}, fn update, {context, verdicts} ->
        {context, verdict} = reason_update(state.reasoner, context, update)
        {context, Map.put(verdicts, update.event_id, verdict)}
      end)

    %{state | context: context, verdicts: verdicts}
  end

  defp rebuild_from(state, event_id) do
    case Enum.split_while(state.updates, &(&1.event_id != event_id)) do
      {_prefix, []} ->
        rebuild(state)

      {prefix, suffix} ->
        case fold_known_prefix(state, prefix) do
          {:ok, prefix_context, prefix_verdicts} ->
            {context, verdicts} =
              Enum.reduce(suffix, {prefix_context, prefix_verdicts}, fn update,
                                                                        {context, verdicts} ->
                {context, verdict} = reason_update(state.reasoner, context, update)
                {context, Map.put(verdicts, update.event_id, verdict)}
              end)

            %{state | context: context, verdicts: verdicts}

          :error ->
            rebuild(state)
        end
    end
  end

  defp fold_known_prefix(state, prefix) do
    Enum.reduce_while(prefix, {:ok, state.base_context, %{}}, fn update,
                                                                 {:ok, context, verdicts} ->
      case Map.fetch(state.verdicts, update.event_id) do
        {:ok, verdict} ->
          context = fold_context(context, update.sample, verdict)
          {:cont, {:ok, context, Map.put(verdicts, update.event_id, verdict)}}

        :error ->
          {:halt, :error}
      end
    end)
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

  defp maybe_suppress_verdict(state, event_id) do
    if warming?(state) and anomalous?(state.verdicts[event_id]) do
      %{state | verdicts: Map.update!(state.verdicts, event_id, &suppress_verdict/1)}
    else
      state
    end
  end

  defp anomalous?(verdict) when is_map(verdict) do
    Map.get(verdict, :anomalous, Map.get(verdict, "anomalous", false)) == true
  end

  defp anomalous?(_verdict), do: false

  defp suppress_verdict(nil), do: nil

  defp suppress_verdict(verdict) do
    state = Map.get(verdict, :state, Map.get(verdict, "state"))
    reason = Map.get(verdict, :reason, Map.get(verdict, "reason"))

    verdict
    |> Map.put(:state, "warming")
    |> Map.put(:anomalous, false)
    |> Map.put(:suppressed, true)
    |> Map.put(:suppressed_state, state)
    |> Map.put(:reason, reason || "context warming")
  end

  defp warming?(state) do
    state.suppress_until_warmed? and not state.checkpoint_restored? and
      state.live_update_count < state.context.min_samples
  end

  defp seed_baseline(%{checkpoint_restored?: true} = state, _sample), do: state
  defp seed_baseline(%{updates: [_ | _]} = state, _sample), do: state

  defp seed_baseline(state, sample) do
    case state.baseline_seeder.seed(sample, state.baseline_seed_opts) do
      {:ok, []} ->
        state

      {:ok, values} ->
        baseline =
          values
          |> Enum.filter(&is_number/1)
          |> Enum.take(-state.base_context.window_size)

        seeded = %{state.base_context | baseline: baseline}
        %{state | base_context: seeded, context: seeded}

      {:error, reason} ->
        Logger.warning("anomaly baseline seed failed",
          series_key: state.series_key,
          reason: inspect(reason)
        )

        state
    end
  end

  defp apply_series_config(%{checkpoint_restored?: true} = state, _sample), do: state
  defp apply_series_config(%{series_config_applied?: true} = state, _sample), do: state

  defp apply_series_config(state, sample) do
    tuning = state.series_config_resolver.resolve(sample, state.series_config_opts)

    context =
      SeriesConfig.apply_to_context(state.base_context, tuning, state.context_overrides)

    %{state | base_context: context, context: context, series_config_applied?: true}
  end

  defp load_checkpoint(state) do
    case state.checkpoint_store.load(state.series_key, state.checkpoint_opts) do
      {:ok, nil} ->
        state

      {:ok, %{} = checkpoint} ->
        restore_checkpoint(state, checkpoint)

      {:error, reason} ->
        Logger.warning("anomaly context checkpoint load failed",
          series_key: state.series_key,
          reason: inspect(reason)
        )

        state
    end
  end

  defp restore_checkpoint(state, checkpoint) do
    base_context =
      checkpoint
      |> checkpoint_value(:base_context, state.base_context)
      |> normalize_context(state.base_context)

    context =
      checkpoint
      |> checkpoint_value(:context, base_context)
      |> normalize_context(base_context)

    %{
      state
      | updates:
          checkpoint
          |> checkpoint_value(:updates, [])
          |> Enum.map(&deserialize_update/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(& &1.order_key)
          |> keep_trimmed_updates(state.max_events),
        verdicts:
          checkpoint
          |> checkpoint_value(:verdicts, %{})
          |> normalize_verdicts(),
        base_context: base_context,
        context: context,
        checkpoint_restored?: true,
        series_config_applied?: true,
        live_update_count: 0
    }
  end

  defp save_checkpoint(state) do
    case state.checkpoint_store.save(
           state.series_key,
           checkpoint_payload(state),
           state.checkpoint_opts
         ) do
      :ok ->
        state

      {:error, reason} ->
        Logger.warning("anomaly context checkpoint save failed",
          series_key: state.series_key,
          reason: inspect(reason)
        )

        state
    end
  end

  defp checkpoint_payload(state) do
    %{
      version: 1,
      series_key: state.series_key,
      updates: Enum.map(state.updates, &serialize_update/1),
      verdicts: state.verdicts,
      base_context: state.base_context,
      context: state.context,
      saved_at_unix_nano: System.system_time(:nanosecond)
    }
  end

  defp serialize_update(update) do
    %{
      event_id: update.event_id,
      order_key: encode_term(update.order_key),
      sample: update.sample
    }
  end

  defp deserialize_update(%{} = update) do
    with event_id when is_binary(event_id) <- checkpoint_value(update, :event_id),
         {:ok, order_key} <- decode_term(checkpoint_value(update, :order_key)),
         %{} = sample <- checkpoint_value(update, :sample, %{}) do
      %{
        event_id: event_id,
        order_key: order_key,
        sample: normalize_sample(sample)
      }
    else
      _ -> nil
    end
  end

  defp deserialize_update(_update), do: nil

  defp encode_term(term) do
    term
    |> :erlang.term_to_binary()
    |> Base.url_encode64(padding: false)
  end

  defp decode_term(value) when is_binary(value) do
    with {:ok, binary} <- Base.url_decode64(value, padding: false) do
      {:ok, :erlang.binary_to_term(binary, [:safe])}
    end
  rescue
    ArgumentError -> :error
  end

  defp decode_term(_value), do: :error

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

  defp context_from_opts(opts) do
    %{
      baseline: [],
      min_samples: Keyword.get(opts, :min_samples, @default_min_samples),
      window_size: Keyword.get(opts, :window_size, @default_window_size),
      n_sigma: Keyword.get(opts, :n_sigma, @default_n_sigma),
      confirm_slots: Keyword.get(opts, :confirm_slots, @default_confirm_slots),
      consecutive_anomalous: 0
    }
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

  defp normalize_context(context, fallback) when is_map(context) do
    %{
      baseline:
        context
        |> checkpoint_value(:baseline, fallback.baseline)
        |> numeric_list(fallback.baseline),
      min_samples: positive_int(checkpoint_value(context, :min_samples), fallback.min_samples),
      window_size: positive_int(checkpoint_value(context, :window_size), fallback.window_size),
      n_sigma: number(checkpoint_value(context, :n_sigma), fallback.n_sigma),
      seasonal_n_sigma:
        optional_number(checkpoint_value(context, :seasonal_n_sigma), fallback[:seasonal_n_sigma]),
      trend_n_sigma:
        optional_number(checkpoint_value(context, :trend_n_sigma), fallback[:trend_n_sigma]),
      seasonal_sensitivity:
        optional_number(
          checkpoint_value(context, :seasonal_sensitivity),
          fallback[:seasonal_sensitivity]
        ),
      rolling_enabled:
        optional_boolean(checkpoint_value(context, :rolling_enabled), fallback[:rolling_enabled]),
      seasonal_enabled:
        optional_boolean(
          checkpoint_value(context, :seasonal_enabled),
          fallback[:seasonal_enabled]
        ),
      trend_enabled:
        optional_boolean(checkpoint_value(context, :trend_enabled), fallback[:trend_enabled]),
      seasonal_min_samples:
        optional_positive_int(
          checkpoint_value(context, :seasonal_min_samples),
          fallback[:seasonal_min_samples]
        ),
      trend_min_samples:
        optional_positive_int(
          checkpoint_value(context, :trend_min_samples),
          fallback[:trend_min_samples]
        ),
      metric_class: checkpoint_value(context, :metric_class, fallback[:metric_class]),
      metric_group: checkpoint_value(context, :metric_group, fallback[:metric_group]),
      series_key: checkpoint_value(context, :series_key, fallback[:series_key]),
      confirm_slots:
        positive_int(checkpoint_value(context, :confirm_slots), fallback.confirm_slots),
      consecutive_anomalous:
        non_negative_int(
          checkpoint_value(context, :consecutive_anomalous),
          fallback.consecutive_anomalous
        )
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_context(_context, fallback), do: fallback

  defp numeric_list(values, _fallback) when is_list(values), do: Enum.filter(values, &is_number/1)
  defp numeric_list(_values, fallback), do: fallback

  defp normalize_sample(sample) do
    %{
      series_key: checkpoint_value(sample, :series_key),
      event_id: checkpoint_value(sample, :event_id),
      order_key: checkpoint_value(sample, :order_key),
      value: checkpoint_value(sample, :value),
      observed_at_unix_nano: checkpoint_value(sample, :observed_at_unix_nano),
      subject: checkpoint_value(sample, :subject),
      metric_class: checkpoint_value(sample, :metric_class),
      metadata: checkpoint_value(sample, :metadata, %{})
    }
  end

  defp normalize_verdicts(verdicts) when is_map(verdicts) do
    Map.new(verdicts, fn {event_id, verdict} -> {event_id, normalize_verdict(verdict)} end)
  end

  defp normalize_verdicts(_verdicts), do: %{}

  defp normalize_verdict(verdict) when is_map(verdict) do
    [
      :state,
      :anomalous,
      :breached,
      :include_in_baseline,
      :next_consecutive_anomalous,
      :score,
      :reason,
      :baseline_count,
      :sample_value,
      :observed_at_unix_nano,
      :suppressed,
      :suppressed_state
    ]
    |> Enum.reduce(%{}, fn key, normalized ->
      put_checkpoint_value(normalized, key, verdict)
    end)
    |> put_normalized_signals(verdict)
  end

  defp normalize_verdict(_verdict), do: %{}

  defp put_normalized_signals(normalized, verdict) do
    if checkpoint_has_key?(verdict, :signals) do
      Map.put(normalized, :signals, normalize_signals(checkpoint_value(verdict, :signals)))
    else
      normalized
    end
  end

  defp normalize_signals(signals) when is_list(signals) do
    signals
    |> Enum.map(&normalize_signal/1)
    |> Enum.reject(&(&1 == %{}))
  end

  defp normalize_signals(_signals), do: []

  defp normalize_signal(signal) when is_map(signal) do
    Enum.reduce(
      [
        :name,
        :enabled,
        :ready,
        :breached,
        :score,
        :threshold,
        :sample_count,
        :mean,
        :stddev,
        :reason
      ],
      %{},
      fn key, normalized ->
        put_checkpoint_value(normalized, key, signal)
      end
    )
  end

  defp normalize_signal(_signal), do: %{}

  defp put_checkpoint_value(normalized, key, values) do
    if checkpoint_has_key?(values, key) do
      Map.put(normalized, key, checkpoint_value(values, key))
    else
      normalized
    end
  end

  defp checkpoint_has_key?(map, key) when is_map(map) do
    Map.has_key?(map, key) or Map.has_key?(map, to_string(key))
  end

  defp checkpoint_value(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp positive_int(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, fallback), do: fallback

  defp non_negative_int(value, _fallback) when is_integer(value) and value >= 0, do: value
  defp non_negative_int(_value, fallback), do: fallback

  defp number(value, _fallback) when is_number(value), do: value
  defp number(_value, fallback), do: fallback

  defp optional_number(value, _fallback) when is_number(value), do: value
  defp optional_number(_value, fallback), do: fallback

  defp optional_positive_int(value, _fallback) when is_integer(value) and value > 0, do: value
  defp optional_positive_int(_value, fallback), do: fallback

  defp optional_boolean(value, _fallback) when is_boolean(value), do: value
  defp optional_boolean(_value, fallback), do: fallback

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

  defp keep_trimmed_updates(updates, max_events) do
    {updates, _dropped} = trim_updates(updates, max_events)
    updates
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
