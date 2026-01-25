defmodule ServiceRadar.Observability.PluginResultIngestor do
  @moduledoc """
  Ingests plugin results (`serviceradar.plugin_result.v1`) into service_status
  and timeseries_metrics.
  """

  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.Observability.{ServiceStatus, TimeseriesMetric}

  @spec ingest(map() | list(), map()) :: :ok | {:error, term()}
  def ingest(payload, status) when is_map(payload) do
    actor = SystemActor.system(:plugin_result_ingestor)
    created_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    observed_at = resolve_observed_at(payload, status)
    summary = resolve_summary(payload)
    status_label = fetch_string(payload, ["status"])
    available = resolve_available(status, status_label)

    status_row =
      build_status_row(
        payload,
        status,
        observed_at,
        created_at,
        summary,
        available
      )

    with :ok <- insert_status(status_row, actor),
         :ok <- insert_metrics(payload, status, observed_at, created_at, actor) do
      :ok
    end
  rescue
    e ->
      Logger.error("Plugin result ingest failed: #{inspect(e)}")
      {:error, e}
  end

  def ingest(payload, status) when is_list(payload) do
    payload
    |> Enum.find(&is_map/1)
    |> case do
      nil -> {:error, :invalid_payload}
      entry -> ingest(entry, status)
    end
  end

  def ingest(_payload, _status), do: {:error, :invalid_payload}

  defp insert_status(row, actor) do
    case Ash.create(ServiceStatus, row,
           actor: actor,
           domain: ServiceRadar.Observability,
           return_records?: false
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
      other -> {:error, other}
    end
  end

  defp resolve_observed_at(payload, status) do
    FieldParser.parse_timestamp(
      fetch_value(payload, ["observed_at", "observedAt"]) ||
        status[:agent_timestamp] ||
        status[:timestamp]
    )
  end

  defp resolve_summary(payload) do
    fetch_string(payload, ["summary", "message"]) ||
      fetch_string(payload, ["status"])
  end

  defp resolve_available(status, status_label) do
    case status[:available] do
      true -> true
      false -> false
      _ -> plugin_status_available(status_label)
    end
  end

  defp resolve_service_name(status) do
    case status[:service_name] do
      name when is_binary(name) and name != "" -> name
      _ -> "plugin"
    end
  end

  defp resolve_service_type(status) do
    case status[:service_type] do
      type when is_binary(type) and type != "" -> type
      _ -> "plugin"
    end
  end

  defp resolve_gateway_id(status) do
    case status[:gateway_id] do
      id when is_binary(id) and id != "" -> id
      _ -> "unknown"
    end
  end

  defp build_status_row(payload, status, observed_at, created_at, summary, available) do
    %{
      timestamp: observed_at,
      gateway_id: resolve_gateway_id(status),
      agent_id: status[:agent_id],
      service_name: resolve_service_name(status),
      service_type: resolve_service_type(status),
      available: available,
      message: summary,
      details: FieldParser.encode_json(payload),
      partition: status[:partition],
      created_at: created_at
    }
  end

  defp insert_metrics(payload, status, observed_at, created_at, actor) do
    rows =
      payload
      |> extract_metrics()
      |> Enum.map(&build_metric_row(&1, payload, status, observed_at, created_at))
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(rows) do
      :ok
    else
      case Ash.bulk_create(rows, TimeseriesMetric, :create,
             actor: actor,
             domain: ServiceRadar.Observability,
             return_records?: false,
             return_errors?: true,
             stop_on_error?: false,
             upsert?: true,
             upsert_identity: :unique_timeseries_metric,
             upsert_fields: []
           ) do
        %Ash.BulkResult{status: :success} -> :ok
        %Ash.BulkResult{status: :error, errors: errors} = result ->
          {:error, errors || result}
        {:ok, _} -> :ok
        {:error, error} -> {:error, error}
        other -> {:error, other}
      end
    end
  end

  defp extract_metrics(%{"metrics" => metrics}) when is_list(metrics), do: metrics
  defp extract_metrics(%{metrics: metrics}) when is_list(metrics), do: metrics
  defp extract_metrics(_), do: []

  defp build_metric_row(metric, payload, status, observed_at, created_at) when is_map(metric) do
    name = fetch_string(metric, ["name", "metric", "metric_name", "metricName"])

    case parse_metric_value(fetch_value(metric, ["value", "val", "metric_value", "metricValue"])) do
      {:ok, value} when is_binary(name) and name != "" ->
        unit = fetch_string(metric, ["unit", "u"])
        tags = build_tags(payload)
        metadata = build_metadata(metric, payload)

        %{
          timestamp: observed_at,
          gateway_id: status[:gateway_id] || "unknown",
          agent_id: status[:agent_id],
          metric_name: name,
          metric_type: "plugin",
          value: FieldParser.parse_value(value),
          unit: unit,
          tags: tags,
          partition: status[:partition],
          metadata: metadata,
          created_at: created_at
        }

      _ ->
        nil
    end
  end

  defp build_metric_row(_metric, _payload, _status, _observed_at, _created_at), do: nil

  defp build_tags(payload) do
    payload
    |> fetch_value(["labels", "label"])
    |> normalize_labels()
  end

  defp build_metadata(metric, payload) do
    %{}
    |> maybe_put("warn", parse_metric_number(fetch_value(metric, ["warn", "warning"])))
    |> maybe_put("crit", parse_metric_number(fetch_value(metric, ["crit", "critical"])))
    |> maybe_put("min", parse_metric_number(fetch_value(metric, ["min"])))
    |> maybe_put("max", parse_metric_number(fetch_value(metric, ["max"])))
    |> maybe_put("perfdata", fetch_string(payload, ["perfdata"]))
  end

  defp normalize_labels(nil), do: %{}

  defp normalize_labels(labels) when is_map(labels) do
    Enum.reduce(labels, %{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), value)
    end)
  end

  defp normalize_labels(_), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp fetch_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      Map.get(map, key) || Map.get(map, to_string(key))
    end)
  end

  defp fetch_value(_map, _keys), do: nil

  defp fetch_string(map, keys) do
    case fetch_value(map, keys) do
      value when is_binary(value) -> String.trim(value)
      value when is_atom(value) -> Atom.to_string(value)
      value when is_integer(value) -> Integer.to_string(value)
      value when is_float(value) -> Float.to_string(value)
      _ -> nil
    end
  end

  defp parse_metric_value(nil), do: :error
  defp parse_metric_value(value) when is_number(value), do: {:ok, value / 1}

  defp parse_metric_value(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> {:ok, parsed}
      :error -> :error
    end
  end

  defp parse_metric_value(_), do: :error

  defp parse_metric_number(nil), do: nil
  defp parse_metric_number(value) when is_number(value), do: value / 1

  defp parse_metric_number(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp parse_metric_number(_), do: nil

  defp plugin_status_available(nil), do: false

  defp plugin_status_available(status) do
    case String.upcase(to_string(status)) do
      "OK" -> true
      "WARNING" -> true
      "CRITICAL" -> false
      "UNKNOWN" -> false
      _ -> false
    end
  end
end
