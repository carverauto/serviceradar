defmodule ServiceRadar.Observability.AnomalyDetection.CounterNormalizer do
  @moduledoc """
  Converts cumulative monotonic counter samples into rates for anomaly analysis.

  Gauge values are meaningful as-is. Cumulative counters are only meaningful after
  comparing two points from the same reset lineage, so the first point and reset
  intervals are retained as state but not emitted to the detector.
  """

  @default_table __MODULE__.State
  @default_max_gap_ns to_timeout(hour: 2) * 1_000_000
  @counter32_modulus 4_294_967_296
  @max_rate_key :max_counter_rate_per_second

  @type sample :: map()
  @type drop_reason ::
          :counter_warmup
          | :counter_reset
          | :counter_decrease
          | :counter64_decrease
          | :counter_non_monotonic_time
          | :counter_max_gap
          | :counter_invalid_value

  @doc """
  Returns the process-wide table used by the anomaly pipeline.
  """
  @spec default_table() :: atom()
  def default_table, do: @default_table

  @doc """
  Clears the default or supplied state table for tests and controlled restarts.
  """
  @spec reset_table(atom() | :ets.tid()) :: :ok
  def reset_table(table \\ @default_table) do
    if is_atom(table) do
      case :ets.whereis(table) do
        :undefined -> :ok
        tid -> :ets.delete_all_objects(tid)
      end
    else
      :ets.delete_all_objects(table)
    end
  end

  @doc """
  Normalizes a list of samples, dropping intervals that cannot produce a safe rate.
  """
  @spec normalize_samples([sample()], keyword()) :: [sample()]
  def normalize_samples(samples, opts \\ []) when is_list(samples) do
    table = Keyword.get(opts, :table, @default_table)
    ensure_table(table)

    Enum.flat_map(samples, fn sample ->
      case normalize_sample(sample, table, opts) do
        {:ok, normalized} -> [normalized]
        {:drop, _reason} -> []
      end
    end)
  end

  @doc """
  Normalizes one sample using the supplied ETS table.
  """
  @spec normalize_sample(sample(), atom() | :ets.tid(), keyword()) ::
          {:ok, sample()} | {:drop, drop_reason()}
  def normalize_sample(sample, table \\ @default_table, opts \\ []) when is_map(sample) do
    ensure_table(table)

    if cumulative_monotonic?(sample) do
      normalize_counter_sample(sample, table, opts)
    else
      {:ok, sample}
    end
  end

  defp normalize_counter_sample(sample, table, opts) do
    with {:ok, value} <- counter_value(sample),
         {:ok, timestamp} <- counter_timestamp(sample) do
      state = %{
        value: value,
        timestamp: timestamp,
        reset_anchor: reset_anchor(sample)
      }

      case :ets.lookup(table, sample.series_key) do
        [] ->
          :ets.insert(table, {sample.series_key, state})
          {:drop, :counter_warmup}

        [{_series_key, previous}] ->
          normalize_counter_interval(sample, previous, state, table, opts)
      end
    else
      :error -> {:drop, :counter_invalid_value}
    end
  end

  defp normalize_counter_interval(sample, previous, current, table, opts) do
    cond do
      reset_anchor_changed?(previous.reset_anchor, current.reset_anchor) ->
        store_state(table, sample.series_key, current)
        {:drop, :counter_reset}

      current.timestamp <= previous.timestamp ->
        {:drop, :counter_non_monotonic_time}

      current.timestamp - previous.timestamp > max_gap_ns(opts) ->
        store_state(table, sample.series_key, current)
        {:drop, :counter_max_gap}

      true ->
        elapsed_seconds = (current.timestamp - previous.timestamp) / 1_000_000_000

        sample
        |> interval_delta(previous.value, current.value, elapsed_seconds)
        |> case do
          {:ok, delta} ->
            store_state(table, sample.series_key, current)
            {:ok, rate_sample(sample, previous, current, delta)}

          {:drop, reason} ->
            store_state(table, sample.series_key, current)
            {:drop, reason}
        end
    end
  end

  defp interval_delta(_sample, previous, current, _elapsed_seconds) when current >= previous do
    {:ok, current - previous}
  end

  defp interval_delta(sample, previous, current, elapsed_seconds) do
    cond do
      counter_width(sample) == 32 and
          plausible_counter32_wrap?(sample, previous, current, elapsed_seconds) ->
        {:ok, @counter32_modulus - previous + current}

      counter_width(sample) == 64 ->
        {:drop, :counter64_decrease}

      true ->
        {:drop, :counter_decrease}
    end
  end

  defp rate_sample(sample, previous, current, delta) do
    elapsed_seconds = (current.timestamp - previous.timestamp) / 1_000_000_000
    rate = delta / elapsed_seconds

    metadata =
      sample
      |> Map.get(:metadata, %{})
      |> Map.put(:counter_normalized, true)
      |> Map.put(:counter_raw_value, current.value)
      |> Map.put(:counter_previous_raw_value, previous.value)
      |> Map.put(:counter_delta, delta)
      |> Map.put(:counter_elapsed_seconds, elapsed_seconds)
      |> Map.put(:counter_interval_start_unix_nano, previous.timestamp)
      |> Map.put(:counter_rate_unit, rate_unit(sample))

    %{sample | value: rate, metadata: metadata}
  end

  defp cumulative_monotonic?(sample) do
    metadata = Map.get(sample, :metadata, %{})

    metric_kind = metric_kind(metadata)

    metric_kind in ["sum", "counter"] and
      metadata_value(metadata, :temporality) == "cumulative" and
      truthy?(metadata_value(metadata, :is_monotonic))
  end

  defp metric_kind(metadata) do
    metadata_value(metadata, :kind) ||
      metadata_value(metadata, :metric_kind) ||
      semantic_metric_type(metadata_value(metadata, :metric_type))
  end

  defp semantic_metric_type(value) when value in ["sum", "counter", "gauge", "histogram"],
    do: value

  defp semantic_metric_type(_value), do: nil

  defp counter_value(%{metadata: metadata} = sample) when is_map(metadata) do
    case metadata_value(metadata, :raw_value) || metadata_value(metadata, :counter_raw_value) do
      value when not is_nil(value) -> counter_number(value)
      nil -> counter_number(Map.get(sample, :value))
    end
  end

  defp counter_value(%{value: value}), do: counter_number(value)

  defp counter_number(value) when is_integer(value), do: {:ok, value}

  defp counter_number(value) when is_float(value) and value >= 0 do
    rounded = round(value)

    if rounded == value do
      {:ok, rounded}
    else
      {:ok, value}
    end
  end

  defp counter_number(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp counter_number(_value), do: :error

  defp counter_timestamp(%{observed_at_unix_nano: timestamp})
       when is_integer(timestamp) and timestamp >= 0,
       do: {:ok, timestamp}

  defp counter_timestamp(_sample), do: :error

  defp reset_anchor(sample) do
    metadata = Map.get(sample, :metadata, %{})

    metadata_value(metadata, :start_time_unix_nano) ||
      metadata_value(metadata, :reset_anchor) ||
      metadata_value(metadata, :counter_reset_anchor) ||
      metadata_value(metadata, :boot_id) ||
      metadata_value(metadata, :boot_time_unix_nano)
  end

  defp reset_anchor_changed?(nil, _current), do: false
  defp reset_anchor_changed?(_previous, nil), do: false
  defp reset_anchor_changed?(previous, current), do: previous != current

  defp plausible_counter32_wrap?(sample, previous, current, elapsed_seconds) do
    delta = @counter32_modulus - previous + current
    max_rate = max_counter_rate(sample)

    is_number(elapsed_seconds) and elapsed_seconds > 0 and delta / elapsed_seconds <= max_rate
  end

  defp counter_width(sample) do
    metadata = Map.get(sample, :metadata, %{})

    width =
      metadata_value(metadata, :counter_width) ||
        metadata_value(metadata, :counter_bits) ||
        metadata_value(metadata, :pdu_width)

    normalize_counter_width(width)
  end

  defp max_counter_rate(sample) do
    metadata = Map.get(sample, :metadata, %{})

    case metadata_value(metadata, @max_rate_key) do
      value when is_number(value) and value > 0 -> value
      _ -> @counter32_modulus
    end
  end

  defp max_gap_ns(opts) do
    case Keyword.get(opts, :max_gap_ns, @default_max_gap_ns) do
      value when is_integer(value) and value > 0 -> value
      _ -> @default_max_gap_ns
    end
  end

  defp rate_unit(sample) do
    metadata = Map.get(sample, :metadata, %{})

    case metadata_value(metadata, :unit) || Map.get(sample, :unit) do
      value when is_binary(value) and value != "" -> "#{value}/s"
      _ -> "1/s"
    end
  end

  defp store_state(table, series_key, state), do: :ets.insert(table, {series_key, state})

  defp ensure_table(table) when is_atom(table) do
    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

      _tid ->
        table
    end
  end

  defp ensure_table(_table), do: :ok

  defp metadata_value(metadata, key) when is_map(metadata) and is_atom(key) do
    case Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key)) do
      nil ->
        nested = nested_metadata(metadata)
        Map.get(nested, key) || Map.get(nested, Atom.to_string(key))

      value ->
        value
    end
  end

  defp metadata_value(metadata, key) when is_map(metadata), do: Map.get(metadata, key)
  defp metadata_value(_metadata, _key), do: nil

  defp nested_metadata(metadata) when is_map(metadata) do
    case Map.get(metadata, :metadata) || Map.get(metadata, "metadata") do
      nested when is_map(nested) -> nested
      _ -> %{}
    end
  end

  defp nested_metadata(_metadata), do: %{}

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?(_value), do: false

  defp normalize_counter_width(value) when value in [32, 64], do: value

  defp normalize_counter_width(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {width, ""} when width in [32, 64] -> width
      _ -> nil
    end
  end

  defp normalize_counter_width(_value), do: nil
end
