defmodule ServiceRadar.Observability.AnomalyDetection.NativeContextEngine.Checkpoint do
  @moduledoc false

  alias ServiceRadar.Observability.AnomalyDetection.ContextCheckpoint
  alias ServiceRadar.Observability.CausalReasoner

  require Logger

  @spec queue_series(tuple(), MapSet.t(), map(), atom()) :: map()
  def queue_series(groups, error_indexes, state, seen_events_table) do
    entries = series_entries(groups, error_indexes)

    cond do
      MapSet.size(entries) == 0 ->
        state

      state.checkpoint_flush_interval_ms <= 0 ->
        persist_entries(state, entries, seen_events_table)

      true ->
        state
        |> Map.update!(:checkpoint_pending_series, &MapSet.union(&1, entries))
        |> schedule_flush()
    end
  end

  @spec cancel_flush(map()) :: map()
  def cancel_flush(%{checkpoint_flush_ref: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref, async: false, info: false)
    %{state | checkpoint_flush_ref: nil}
  end

  def cancel_flush(state), do: state

  @spec flush_pending(map(), atom()) :: map()
  def flush_pending(%{checkpoint_pending_series: pending} = state, seen_events_table) do
    state
    |> Map.put(:checkpoint_pending_series, MapSet.new())
    |> persist_entries(pending, seen_events_table)
  end

  @spec load(String.t(), non_neg_integer(), map()) :: :restored | :missing
  def load(key, shard_index, context) do
    checkpoint_store = Keyword.get(context.opts, :checkpoint_store, ContextCheckpoint)
    checkpoint_opts = Keyword.get(context.opts, :checkpoint_opts, [])

    case checkpoint_store.load(native_checkpoint_key(key), checkpoint_opts) do
      {:ok, nil} ->
        :missing

      {:ok, %{} = checkpoint} ->
        restore(key, shard_index, checkpoint, context)

      {:error, reason} ->
        Logger.warning("native anomaly checkpoint load failed",
          series_key: key,
          reason: inspect(reason)
        )

        :missing
    end
  end

  defp series_entries(groups, error_indexes) do
    Enum.reduce(0..(tuple_size(groups) - 1), MapSet.new(), fn shard_index, acc ->
      groups
      |> elem(shard_index)
      |> Enum.reduce(acc, fn
        {index, key, _context, _value, _observed_at}, acc
        when is_binary(key) and key != "" ->
          if MapSet.member?(error_indexes, index) do
            acc
          else
            MapSet.put(acc, {key, shard_index})
          end

        _input, acc ->
          acc
      end)
    end)
  end

  defp schedule_flush(%{checkpoint_flush_ref: ref} = state) when is_reference(ref), do: state

  defp schedule_flush(state) do
    ref = Process.send_after(self(), :flush_checkpoint, state.checkpoint_flush_interval_ms)
    %{state | checkpoint_flush_ref: ref}
  end

  defp persist_entries(state, entries, seen_events_table) do
    Enum.reduce(entries, state, fn {key, shard_index}, state ->
      persist(state, key, shard_index, seen_events_table)
    end)
  end

  defp persist(state, key, shard_index, seen_events_table) do
    resource = elem(state.resources, shard_index)

    case CausalReasoner.export_series(resource, key) do
      {:ok, nil} ->
        state

      {:ok, %{} = snapshot} ->
        payload = payload(snapshot, key, seen_events_table)

        case state.checkpoint_store.save(
               native_checkpoint_key(key),
               payload,
               state.checkpoint_opts
             ) do
          :ok ->
            state

          {:ok, _revision} ->
            state

          {:error, reason} ->
            Logger.warning("native anomaly checkpoint save failed",
              series_key: key,
              reason: inspect(reason)
            )

            state
        end

      {:error, reason} ->
        Logger.warning("native anomaly checkpoint export failed",
          series_key: key,
          reason: inspect(reason)
        )

        state
    end
  end

  defp payload(snapshot, key, seen_events_table) do
    %{
      engine: "native_context_engine",
      version: 1,
      series_key: key,
      snapshot: snapshot,
      seen_events: seen_events_for_series(key, seen_events_table),
      saved_at_unix_nano: System.system_time(:nanosecond)
    }
  end

  defp seen_events_for_series(key, seen_events_table) do
    seen_events_table
    |> :ets.match({{key, :"$1"}, :"$2"})
    |> Enum.map(fn [inner_key, seen_at_ms] ->
      %{event_key: encode_term({key, inner_key}), seen_at_ms: seen_at_ms}
    end)
  end

  defp restore(key, shard_index, checkpoint, context) do
    with true <- checkpoint_value(checkpoint, :engine) == "native_context_engine",
         1 <- checkpoint_value(checkpoint, :version),
         %{} = snapshot <- checkpoint_value(checkpoint, :snapshot),
         {:ok, active?} <-
           CausalReasoner.import_series(elem(context.resources, shard_index), snapshot) do
      restore_seen_events(
        checkpoint_value(checkpoint, :seen_events, []),
        context.seen_events_table
      )

      restore_open_series(key, active?, context.open_series_table)
      :restored
    else
      {:error, reason} ->
        Logger.warning("native anomaly checkpoint import failed",
          series_key: key,
          reason: inspect(reason)
        )

        :missing

      _invalid ->
        Logger.warning("native anomaly checkpoint invalid; starting fresh", series_key: key)
        :missing
    end
  end

  defp restore_seen_events(events, seen_events_table) when is_list(events) do
    now = System.monotonic_time(:millisecond)

    entries =
      Enum.reduce(events, [], fn event, acc ->
        with %{} <- event,
             encoded when is_binary(encoded) <- checkpoint_value(event, :event_key),
             {:ok, event_key} <- decode_term(encoded),
             true <- match?({_series_key, _inner_key}, event_key) do
          seen_at_ms = checkpoint_value(event, :seen_at_ms, now)
          [{event_key, seen_at_ms} | acc]
        else
          _ -> acc
        end
      end)

    case entries do
      [] -> :ok
      entries -> :ets.insert(seen_events_table, entries)
    end
  end

  defp restore_seen_events(_events, _seen_events_table), do: :ok

  defp restore_open_series(key, true, open_series_table) do
    :ets.insert(open_series_table, {key, System.monotonic_time(:millisecond)})
  end

  defp restore_open_series(key, false, open_series_table) do
    :ets.delete(open_series_table, key)
  end

  defp native_checkpoint_key(key), do: "native:" <> key

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

  defp checkpoint_value(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
