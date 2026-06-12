defmodule ServiceRadar.Observability.AnomalyDetection.SeriesConfig do
  @moduledoc """
  Resolves per-series anomaly detection tuning.

  The resolver is deliberately config-backed for the streaming detector phase.
  The later operator-managed CNPG/settings work can replace the source without
  changing the context owner or reasoner contract.
  """

  @default_tuning %{
    rolling_enabled: true,
    seasonal_enabled: false,
    trend_enabled: false,
    min_samples: 30,
    seasonal_min_samples: 30,
    trend_min_samples: 30,
    window_size: 300,
    n_sigma: 3.0,
    seasonal_sensitivity: 1.0,
    trend_n_sigma: 3.0,
    confirm_slots: 5
  }

  @metric_class_defaults %{
    "cpu" => %{window_size: 300, min_samples: 30, n_sigma: 3.0, confirm_slots: 5},
    "mem" => %{window_size: 300, min_samples: 30, n_sigma: 3.0, confirm_slots: 5},
    "disk" => %{window_size: 180, min_samples: 20, n_sigma: 3.0, confirm_slots: 6},
    "interface" => %{window_size: 360, min_samples: 30, n_sigma: 3.5, confirm_slots: 4},
    "red" => %{window_size: 120, min_samples: 20, n_sigma: 3.0, confirm_slots: 3}
  }

  @context_keys [
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
    :metric_class,
    :metric_group,
    :series_key,
    :seasonal_sensitivity
  ]

  @positive_int_keys [:min_samples, :seasonal_min_samples, :trend_min_samples, :window_size]
  @non_negative_int_keys [:confirm_slots]
  @number_keys [:n_sigma, :seasonal_n_sigma, :trend_n_sigma, :seasonal_sensitivity]
  @boolean_keys [:rolling_enabled, :seasonal_enabled, :trend_enabled]
  @known_keys [
                :metric_class_defaults,
                :series_overrides,
                :runtime_config
              ] ++ @context_keys

  @spec resolve(map(), keyword() | map()) :: map()
  def resolve(%{} = sample, opts \\ []) do
    config = merge_config(opts)
    metric_class = string_value(sample, :metric_class)
    metric_group = metric_group(metric_class, string_value(sample, :subject))
    series_key = string_value(sample, :series_key)

    @default_tuning
    |> merge_known(metric_class_defaults(config, "default"))
    |> merge_known(metric_class_defaults(config, metric_group))
    |> merge_known(metric_class_defaults(config, metric_class))
    |> merge_known(series_override(config, series_key))
    |> normalize_tuning(metric_class, metric_group, series_key)
  end

  @spec apply_to_context(map(), map(), map()) :: map()
  def apply_to_context(context, tuning, explicit_overrides \\ %{})
      when is_map(context) and is_map(tuning) and is_map(explicit_overrides) do
    context
    |> Map.merge(Map.take(tuning, @context_keys))
    |> Map.merge(explicit_overrides)
    |> derive_seasonal_threshold()
    |> trim_baseline()
  end

  @spec default_tuning() :: map()
  def default_tuning, do: @default_tuning

  @spec metric_class_defaults() :: map()
  def metric_class_defaults, do: @metric_class_defaults

  defp merge_config(opts) do
    config()
    |> to_plain_map()
    |> deep_merge(runtime_config())
    |> deep_merge(to_plain_map(opts))
  end

  defp metric_class_defaults(_config, nil), do: %{}

  defp metric_class_defaults(config, key) do
    built_in =
      @metric_class_defaults
      |> get_any(key, %{})
      |> to_plain_map()

    configured =
      config
      |> get_any(:metric_class_defaults, %{})
      |> get_any(key, %{})
      |> to_plain_map()

    deep_merge(built_in, configured)
  end

  defp series_override(_config, nil), do: %{}

  defp series_override(config, series_key) do
    config
    |> get_any(:series_overrides, %{})
    |> get_any(series_key, %{})
    |> to_plain_map()
  end

  defp normalize_tuning(tuning, metric_class, metric_group, series_key) do
    tuning
    |> normalize_positive_ints(@positive_int_keys)
    |> normalize_non_negative_ints(@non_negative_int_keys)
    |> normalize_numbers(@number_keys)
    |> normalize_booleans(@boolean_keys)
    |> maybe_put_string(:metric_class, metric_class)
    |> maybe_put_string(:metric_group, metric_group)
    |> maybe_put_string(:series_key, series_key)
  end

  defp normalize_positive_ints(tuning, keys) do
    Enum.reduce(keys, tuning, fn key, acc ->
      case positive_int(get_any(acc, key)) do
        nil -> Map.delete(acc, key)
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp normalize_non_negative_ints(tuning, keys) do
    Enum.reduce(keys, tuning, fn key, acc ->
      case non_negative_int(get_any(acc, key)) do
        nil -> Map.delete(acc, key)
        value -> Map.put(acc, key, max(value, 1))
      end
    end)
  end

  defp normalize_numbers(tuning, keys) do
    Enum.reduce(keys, tuning, fn key, acc ->
      case number(get_any(acc, key)) do
        nil -> Map.delete(acc, key)
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp normalize_booleans(tuning, keys) do
    Enum.reduce(keys, tuning, fn key, acc ->
      case boolean(get_any(acc, key)) do
        nil -> Map.delete(acc, key)
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp derive_seasonal_threshold(context) do
    if Map.has_key?(context, :seasonal_n_sigma) do
      context
    else
      n_sigma = number(Map.get(context, :n_sigma)) || Map.fetch!(@default_tuning, :n_sigma)
      sensitivity = number(Map.get(context, :seasonal_sensitivity)) || 1.0
      Map.put(context, :seasonal_n_sigma, n_sigma / max(sensitivity, 0.1))
    end
  end

  defp trim_baseline(%{baseline: baseline, window_size: window_size} = context)
       when is_list(baseline) and is_integer(window_size) and window_size > 0 do
    %{context | baseline: Enum.take(baseline, -window_size)}
  end

  defp trim_baseline(context), do: context

  defp metric_group("sysmon.cpu", _subject), do: "cpu"
  defp metric_group("sysmon.memory", _subject), do: "mem"
  defp metric_group("sysmon.disk", _subject), do: "disk"
  defp metric_group("snmp", _subject), do: "interface"
  defp metric_group("flow", _subject), do: "interface"
  defp metric_group("otel.metric_point", _subject), do: "red"
  defp metric_group("otel.span_duration", _subject), do: "red"

  defp metric_group(metric_class, subject) do
    cond do
      is_binary(metric_class) and String.starts_with?(metric_class, "sysmon.") ->
        String.trim_leading(metric_class, "sysmon.")

      is_binary(subject) and String.starts_with?(subject, "metrics.snmp.") ->
        "interface"

      is_binary(subject) and String.starts_with?(subject, "otel.metrics.") ->
        "red"

      true ->
        "default"
    end
  end

  defp merge_known(tuning, override) do
    tuning
    |> to_plain_map()
    |> deep_merge(to_plain_map(override))
  end

  defp to_plain_map(nil), do: %{}

  defp to_plain_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {normalize_key(key), normalize_value(value)} end)
  end

  defp to_plain_map(list) when is_list(list) do
    list
    |> Enum.filter(&match?({_key, _value}, &1))
    |> Map.new(fn {key, value} -> {normalize_key(key), normalize_value(value)} end)
  end

  defp to_plain_map(_value), do: %{}

  defp normalize_value(value) when is_map(value) or is_list(value), do: to_plain_map(value)
  defp normalize_value(value), do: value

  defp normalize_key(key) when is_binary(key) do
    Enum.find(@known_keys, key, &(Atom.to_string(&1) == key))
  end

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key), do: to_string(key)

  defp deep_merge(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end

  defp get_any(container, key, default \\ nil)

  defp get_any(container, key, default) when is_map(container) do
    cond do
      Map.has_key?(container, key) ->
        Map.get(container, key)

      is_atom(key) and Map.has_key?(container, Atom.to_string(key)) ->
        Map.get(container, Atom.to_string(key))

      is_binary(key) and Map.has_key?(container, key) ->
        Map.get(container, key)

      true ->
        default
    end
  end

  defp get_any(container, key, default) when is_list(container) do
    container
    |> Enum.find_value(fn
      {^key, value} ->
        {:found, value}

      {candidate, value} when is_atom(key) ->
        if candidate == Atom.to_string(key), do: {:found, value}

      {candidate, value} when is_binary(key) ->
        if candidate == key, do: {:found, value}

      _entry ->
        nil
    end)
    |> case do
      {:found, value} -> value
      nil -> default
    end
  end

  defp get_any(_container, _key, default), do: default

  defp string_value(map, key) do
    case get_any(map, key) do
      value when is_binary(value) and value != "" -> value
      value when not is_nil(value) -> to_string(value)
      _ -> nil
    end
  end

  defp maybe_put_string(map, _key, nil), do: map
  defp maybe_put_string(map, key, value), do: Map.put(map, key, value)

  defp positive_int(value) when is_integer(value) and value > 0, do: value

  defp positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _ -> nil
    end
  end

  defp positive_int(_value), do: nil

  defp non_negative_int(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> number
      _ -> nil
    end
  end

  defp non_negative_int(_value), do: nil

  defp number(value) when is_number(value), do: value * 1.0

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp number(_value), do: nil

  defp boolean(value) when is_boolean(value), do: value
  defp boolean(value) when value in ["true", "1", "yes", "on"], do: true
  defp boolean(value) when value in ["false", "0", "no", "off"], do: false
  defp boolean(_value), do: nil

  defp config do
    case Application.get_env(:serviceradar_core, __MODULE__, %{}) do
      config when is_list(config) ->
        get_any(config, :runtime_config, config)

      config ->
        config
    end
  end

  defp runtime_config do
    to_plain_map(ServiceRadar.Observability.AnomalyConfigRuntime.anomaly_series_config())
  end
end
