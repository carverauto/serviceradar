defmodule ServiceRadar.Observability.AnomalyDetection.NativeContextEngine.Retention do
  @moduledoc false

  alias ServiceRadar.Observability.CausalReasoner

  require Logger

  @spec update_open_series([{integer(), term()}], tuple(), atom()) :: :ok
  def update_open_series(results, sample_lookup, open_series_table) do
    Enum.each(results, fn
      {index, {:ok, verdict}} when index >= 0 ->
        case result_series_key(sample_lookup, index) do
          nil ->
            :ok

          key ->
            if verdict_anomalous?(verdict) do
              :ets.insert(open_series_table, {key, System.monotonic_time(:millisecond)})
            else
              :ets.delete(open_series_table, key)
            end
        end

      _other ->
        :ok
    end)
  end

  @spec enforce_series_limit_budgeted(tuple(), non_neg_integer(), non_neg_integer(), map()) :: :ok
  def enforce_series_limit_budgeted(_resources, max_series, _budget, _tables)
      when max_series <= 0, do: :ok

  def enforce_series_limit_budgeted(resources, max_series, budget, tables) do
    case :ets.info(tables.seen, :size) do
      size when is_integer(size) and size > max_series ->
        evict_series(resources, min(size - max_series, budget), tables)

      _ ->
        :ok
    end
  end

  @spec enforce_series_limit_periodic(map(), map()) :: map()
  def enforce_series_limit_periodic(%{max_series: max_series} = state, _tables)
      when max_series <= 0, do: state

  def enforce_series_limit_periodic(%{resources: resources} = state, tables) do
    case :ets.info(tables.seen, :size) do
      size when is_integer(size) and size > state.max_series ->
        evict_series(resources, min(size - state.max_series, state.eviction_budget), tables)
        state

      _ ->
        state
    end
  end

  @spec prune_seen_events(map(), atom()) :: map()
  def prune_seen_events(%{event_ttl_ms: ttl_ms} = state, seen_events_table) do
    now = System.monotonic_time(:millisecond)

    if ttl_ms > 0 do
      cutoff = now - ttl_ms

      :ets.select_delete(seen_events_table, [
        {{:"$1", :"$2"}, [{:<, :"$2", cutoff}], [true]}
      ])
    end

    case :ets.info(seen_events_table, :size) do
      size when is_integer(size) and size > state.max_seen_events ->
        Logger.warning(
          "native anomaly seen-events table over capacity with all tokens still within TTL; " <>
            "retaining for idempotency. Raise :max_seen_events or lower :event_ttl_ms.",
          size: size,
          max_seen_events: state.max_seen_events,
          event_ttl_ms: ttl_ms
        )

      _ ->
        :ok
    end

    %{state | last_event_prune_ms: now}
  end

  defp evict_series(_resources, count, _tables) when count <= 0, do: :ok

  defp evict_series(resources, count, tables) do
    scan_limit = max(count * 4, count)

    candidates =
      case :ets.select(
             tables.seen,
             [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}],
             scan_limit
           ) do
        :"$end_of_table" -> []
        {rows, _cont} -> rows
      end

    candidates
    |> Enum.reject(fn {key, _shard_index, _last_seen} ->
      :ets.member(tables.open_series, key)
    end)
    |> Enum.sort_by(fn {_key, _shard_index, last_seen} -> last_seen end)
    |> Enum.take(count)
    |> Enum.each(fn {key, shard_index, _last_seen} ->
      forget_series(resources, key, shard_index, tables)
    end)

    :ok
  end

  defp forget_series(resources, key, shard_index, tables) do
    CausalReasoner.forget_series(elem(resources, shard_index), key)
    :ets.delete(tables.seen, key)
    :ets.delete(tables.open_series, key)
    :ets.match_delete(tables.seen_events, {{key, :_}, :_})
    :ok
  end

  defp result_series_key(sample_lookup, index) do
    case elem(sample_lookup, index) do
      %{} = sample -> series_key(sample)
      {_index, key, _event_key, _value, _observed_at, _config} when is_binary(key) -> key
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp series_key(%{series_key: value}) when is_binary(value) and value != "", do: value
  defp series_key(%{"series_key" => value}) when is_binary(value) and value != "", do: value
  defp series_key(_sample), do: nil

  defp verdict_anomalous?(verdict) when is_map(verdict) do
    Map.get(verdict, :anomalous, Map.get(verdict, "anomalous", false)) == true
  end

  defp verdict_anomalous?(_verdict), do: false
end
