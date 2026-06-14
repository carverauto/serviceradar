defmodule ServiceRadar.Observability.AnomalyDetection.NativeContextEngine.BatchPreparation do
  @moduledoc false

  alias ServiceRadar.Observability.AnomalyDetection.NativeContextEngine.Checkpoint
  alias ServiceRadar.Observability.AnomalyDetection.SeriesConfig

  @spec prepared_groups([{non_neg_integer(), list()}], pos_integer()) :: tuple()
  def prepared_groups(shard_batches, shard_count) do
    Enum.reduce(shard_batches, :erlang.make_tuple(shard_count, []), fn
      {shard_index, inputs}, groups
      when is_integer(shard_index) and shard_index >= 0 and shard_index < shard_count and
             is_list(inputs) ->
        put_elem(groups, shard_index, inputs)

      _invalid, groups ->
        groups
    end)
  end

  @spec prepare_events([map()], pos_integer(), keyword(), map()) ::
          {tuple(), list(), list(), list()}
  def prepare_events(samples, shard_count, opts, context) do
    {groups, duplicates, missing, event_entries, _batch_keys} =
      Enum.reduce(
        Enum.with_index(samples),
        {:erlang.make_tuple(shard_count, []), [], [], [], MapSet.new()},
        fn {sample, index}, {groups, duplicates, missing, event_entries, batch_keys} ->
          key = series_key(sample)
          sample_event_key = event_key(sample, key)

          if is_nil(key) do
            {groups, duplicates, [{index, sample, {:error, :missing_series_key}} | missing],
             event_entries, batch_keys}
          else
            shard_index = shard_index(key, shard_count)
            series_context = maybe_context(key, sample, opts, shard_index, context)

            prepare_keyed_event_group(
              sample,
              index,
              key,
              sample_event_key,
              series_context,
              shard_index,
              groups,
              duplicates,
              missing,
              event_entries,
              batch_keys,
              context
            )
          end
        end
      )

    {finalize_groups(groups), duplicates, missing, event_entries}
  end

  @spec prepare_compact_events([tuple()], pos_integer(), keyword(), map()) ::
          {tuple(), list(), list(), list()}
  def prepare_compact_events(samples, shard_count, opts, context) do
    {groups, duplicates, missing, event_entries, _batch_keys} =
      Enum.reduce(samples, {:erlang.make_tuple(shard_count, []), [], [], [], MapSet.new()}, fn
        {index, key, sample_event_key, value, observed_at_unix_nano, series_config} = sample,
        {groups, duplicates, missing, event_entries, batch_keys} ->
          dedup_key =
            compact_event_key(
              key,
              sample_event_key || compact_observed_identity(value, observed_at_unix_nano)
            )

          if valid_series_key?(key) do
            shard_index = shard_index(key, shard_count)
            series_context = maybe_context(key, series_config || %{}, opts, shard_index, context)

            if not is_nil(dedup_key) and
                 (seen_event?(dedup_key, context) or MapSet.member?(batch_keys, dedup_key)) do
              {groups, [{index, sample, {:drop, :duplicate_event}} | duplicates], missing,
               event_entries, batch_keys}
            else
              input = {index, key, series_context, value, observed_at_unix_nano}
              group = elem(groups, shard_index)

              groups =
                put_elem(
                  groups,
                  shard_index,
                  [{compact_sort_key(observed_at_unix_nano, index), input} | group]
                )

              event_entries = maybe_event_entry(event_entries, index, dedup_key)
              batch_keys = maybe_track_batch_key(batch_keys, dedup_key)

              {groups, duplicates, missing, event_entries, batch_keys}
            end
          else
            {groups, duplicates, [{index, sample, {:error, :missing_series_key}} | missing],
             event_entries, batch_keys}
          end
      end)

    {finalize_groups(groups), duplicates, missing, event_entries}
  end

  @spec mark_seen_event_entries(atom(), list(), MapSet.t()) :: :ok
  def mark_seen_event_entries(seen_events_table, event_entries, error_indexes) do
    now = System.monotonic_time(:millisecond)

    entries =
      Enum.reduce(event_entries, [], fn {index, event_key}, acc ->
        if MapSet.member?(error_indexes, index), do: acc, else: [{event_key, now} | acc]
      end)

    case entries do
      [] -> :ok
      entries -> :ets.insert(seen_events_table, entries)
    end
  end

  @spec event_count(tuple()) :: non_neg_integer()
  def event_count(groups) do
    Enum.reduce(0..(tuple_size(groups) - 1), 0, fn shard_index, count ->
      count + length(elem(groups, shard_index))
    end)
  end

  @spec index_set(tuple()) :: MapSet.t()
  def index_set(groups) do
    Enum.reduce(0..(tuple_size(groups) - 1), MapSet.new(), fn shard_index, acc ->
      groups
      |> elem(shard_index)
      |> Enum.reduce(acc, fn {index, _key, _context, _value, _observed_at}, acc ->
        MapSet.put(acc, index)
      end)
    end)
  end

  defp prepare_keyed_event_group(
         sample,
         index,
         key,
         sample_event_key,
         series_context,
         shard_index,
         groups,
         duplicates,
         missing,
         event_entries,
         batch_keys,
         context
       ) do
    if not is_nil(sample_event_key) and
         (seen_event?(sample_event_key, context) or MapSet.member?(batch_keys, sample_event_key)) do
      {groups, [{index, sample, {:drop, :duplicate_event}} | duplicates], missing, event_entries,
       batch_keys}
    else
      input =
        {index, key, series_context, value(sample, :value), value(sample, :observed_at_unix_nano)}

      group = elem(groups, shard_index)
      groups = put_elem(groups, shard_index, [{sort_key(sample), input} | group])
      event_entries = maybe_event_entry(event_entries, index, sample_event_key)
      batch_keys = maybe_track_batch_key(batch_keys, sample_event_key)

      {groups, duplicates, missing, event_entries, batch_keys}
    end
  end

  defp finalize_groups(groups) do
    Enum.reduce(0..(tuple_size(groups) - 1), groups, fn shard_index, groups ->
      sorted =
        groups
        |> elem(shard_index)
        |> Enum.sort_by(fn {sort_key, _input} -> sort_key end)
        |> Enum.map(fn {_sort_key, input} -> input end)

      put_elem(groups, shard_index, sorted)
    end)
  end

  defp maybe_context(nil, _sample, _opts, _shard_index, _context), do: nil

  defp maybe_context(key, sample, opts, shard_index, context) do
    now = System.monotonic_time(:millisecond)

    if :ets.insert_new(context.seen_table, {key, shard_index, now}) do
      case Checkpoint.load(key, shard_index, context.checkpoint_context) do
        :restored ->
          nil

        :missing ->
          SeriesConfig.apply_to_context(
            context.base_context,
            SeriesConfig.resolve(sample, opts),
            context.context_overrides
          )
      end
    else
      touch_series(key, shard_index, context)
      nil
    end
  end

  defp touch_series(nil, _shard_index, _context), do: :ok

  defp touch_series(key, shard_index, context) do
    :ets.insert(context.seen_table, {key, shard_index, System.monotonic_time(:millisecond)})
  end

  defp maybe_track_batch_key(batch_keys, nil), do: batch_keys
  defp maybe_track_batch_key(batch_keys, key), do: MapSet.put(batch_keys, key)

  defp maybe_event_entry(event_entries, _index, nil), do: event_entries

  defp maybe_event_entry(event_entries, index, event_key),
    do: [{index, event_key} | event_entries]

  defp compact_event_key(_key, nil), do: nil
  defp compact_event_key(key, event_key), do: {key, event_key}

  defp compact_observed_identity(_value, nil), do: nil

  defp compact_observed_identity(value, observed_at_unix_nano),
    do: {:observed_at, observed_at_unix_nano, value}

  defp compact_sort_key(observed_at_unix_nano, index), do: {observed_at_unix_nano, index}

  defp sort_key(sample) do
    Map.get(sample, :order_key, Map.get(sample, "order_key")) ||
      value(sample, :observed_at_unix_nano)
  end

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

  defp seen_event?(nil, _context), do: false
  defp seen_event?(key, context), do: :ets.member(context.seen_events_table, key)

  defp shard_index(nil, shard_count), do: :erlang.phash2(:missing_series_key, shard_count)
  defp shard_index(series_key, shard_count), do: :erlang.phash2(series_key, shard_count)

  defp valid_series_key?(value), do: is_binary(value) and value != ""

  defp series_key(%{series_key: value}) when is_binary(value) and value != "", do: value
  defp series_key(%{"series_key" => value}) when is_binary(value) and value != "", do: value
  defp series_key(_sample), do: nil

  defp value(%{} = map, key), do: Map.get(map, key, Map.get(map, to_string(key)))
  defp value(_sample, _key), do: nil
end
