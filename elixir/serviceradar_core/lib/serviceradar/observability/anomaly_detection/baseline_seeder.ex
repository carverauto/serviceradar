defmodule ServiceRadar.Observability.AnomalyDetection.BaselineSeeder do
  @moduledoc """
  Seeds cold anomaly baselines from SRQL queries over hourly metric CAGGs.

  Query templates are configured by metric class. A template can reference
  `{{series_key}}`, `{{metric_class}}`, `{{subject}}`, and metadata fields such
  as `{{metadata.host_id}}` or `{{metadata.device_id}}`.
  """

  @default_value_fields [
    "avg_value",
    "avg_usage_percent",
    "avg_used_bytes",
    "value",
    "usage_percent"
  ]

  @spec seed(map(), keyword()) :: {:ok, [number()]} | {:error, term()}
  def seed(%{} = sample, opts \\ []) do
    config = Keyword.merge(config(), opts)

    if Keyword.get(config, :enabled, false) do
      case query_for(sample, config) do
        nil ->
          {:ok, []}

        query ->
          run_query(query, config)
      end
    else
      {:ok, []}
    end
  end

  defp run_query(query, config) do
    runner = Keyword.get(config, :runner, ServiceRadar.Observability.SRQLRunner)
    runner_opts = Keyword.get(config, :runner_opts, [])

    with {:ok, rows} <- runner.query(query, runner_opts) do
      values =
        rows
        |> Enum.map(&value_from_row(&1, config))
        |> Enum.reject(&is_nil/1)
        |> maybe_reverse(config)

      {:ok, values}
    end
  end

  defp query_for(sample, config) do
    templates = Keyword.get(config, :query_templates, %{})
    metric_class = Map.get(sample, :metric_class) || Map.get(sample, "metric_class")

    template =
      template_value(templates, metric_class) ||
        template_value(templates, to_string(metric_class)) ||
        template_value(templates, :default) ||
        template_value(templates, "default")

    if is_binary(template) and template != "" do
      render_template(template, sample)
    end
  end

  defp template_value(templates, key) when is_map(templates), do: Map.get(templates, key)
  defp template_value(templates, key) when is_list(templates), do: Keyword.get(templates, key)
  defp template_value(_templates, _key), do: nil

  defp render_template(template, sample) do
    Regex.replace(~r/\{\{([A-Za-z0-9_.-]+)\}\}/, template, fn _match, key ->
      sample_value(sample, key)
    end)
  end

  defp sample_value(sample, "series_key"), do: sample |> value(:series_key) |> srql_escape()
  defp sample_value(sample, "metric_class"), do: sample |> value(:metric_class) |> srql_escape()
  defp sample_value(sample, "subject"), do: sample |> value(:subject) |> srql_escape()

  defp sample_value(sample, "metadata." <> key) do
    sample
    |> value(:metadata, %{})
    |> metadata_value(key)
    |> srql_escape()
  end

  defp sample_value(_sample, _key), do: ""

  defp value(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp metadata_value(metadata, key) when is_map(metadata) do
    case Map.fetch(metadata, key) do
      {:ok, value} -> value
      :error -> metadata_atom_value(metadata, key)
    end
  end

  defp metadata_value(_metadata, _key), do: ""

  defp metadata_atom_value(metadata, key) do
    Map.get(metadata, String.to_existing_atom(key), "")
  rescue
    ArgumentError -> ""
  end

  defp srql_escape(nil), do: ""

  defp srql_escape(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp value_from_row(row, config) when is_map(row) do
    config
    |> Keyword.get(:value_fields, @default_value_fields)
    |> Enum.find_value(fn field ->
      case Map.get(row, field, Map.get(row, existing_atom(field))) do
        value when is_number(value) -> value * 1.0
        value when is_binary(value) -> parse_number(value)
        _ -> nil
      end
    end)
  rescue
    ArgumentError -> nil
  end

  defp parse_number(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp maybe_reverse(values, config) do
    if Keyword.get(config, :reverse_rows, true), do: Enum.reverse(values), else: values
  end

  defp existing_atom(field) when is_atom(field), do: field

  defp existing_atom(field) when is_binary(field) do
    String.to_existing_atom(field)
  rescue
    ArgumentError -> :__serviceradar_missing_field__
  end

  defp config do
    Application.get_env(:serviceradar_core, __MODULE__, [])
  end
end
