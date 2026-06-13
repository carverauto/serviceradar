defmodule ServiceRadarAgentGateway.PluginMetricsPublisher do
  @moduledoc """
  Publishes structured plugin result metrics to the high-rate metrics stream.
  """

  alias ServiceRadarAgentGateway.IngressId

  require Logger

  @app :serviceradar_agent_gateway
  @config_key :plugin_metrics_publisher
  @default_subject_prefix "metrics.timeseries"
  @metric_schema "serviceradar.metric.v1"

  @type publish_result :: :ok | :disabled | {:error, term()}

  @spec publish_plugin_metrics(map()) :: publish_result()
  def publish_plugin_metrics(status) do
    config = config()

    if Keyword.get(config, :enabled, false) do
      do_publish(status, config)
    else
      :disabled
    end
  end

  defp do_publish(status, config) do
    with {:ok, payload} <- plugin_payload(status),
         {:ok, encoded_messages} <- encode_messages(status, payload) do
      case encoded_messages do
        [] -> :ok
        messages -> publish_messages(messages, config)
      end
    else
      {:error, reason} = error -> log_publish_error(reason, status, error)
    end
  end

  defp config do
    Application.get_env(@app, @config_key, [])
  end

  defp plugin_payload(%{message: message}) when is_binary(message) do
    with {:ok, decoded} <- Jason.decode(message),
         metrics when is_list(metrics) <- Map.get(decoded, "metrics") do
      {:ok, Map.put(decoded, "metrics", metrics)}
    else
      nil -> {:ok, %{"metrics" => []}}
      {:error, reason} -> {:error, {:invalid_plugin_payload, reason}}
      _other -> {:error, :invalid_plugin_metrics}
    end
  end

  defp plugin_payload(_status), do: {:error, :missing_plugin_message}

  defp encode_messages(status, payload) do
    payload
    |> Map.get("metrics", [])
    |> Enum.reduce_while({:ok, []}, fn metric, {:ok, acc} ->
      case encode_metric(status, payload, metric) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, message} -> {:cont, {:ok, [message | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      error -> error
    end
  end

  defp encode_metric(status, payload, metric) when is_map(metric) do
    name = metric_name(metric)
    value = metric_value(metric)

    if is_binary(name) and name != "" and is_number(value) do
      metric_type = metric_type(metric, name)
      ingress_context = ingress_context(status)
      envelope = metric_envelope(status, payload, metric, name, metric_type, value, ingress_context)

      case Jason.encode(envelope) do
        {:ok, encoded} -> {:ok, {subject(metric_type, name), encoded, ingress_context}}
        {:error, reason} -> {:error, {:encode_failed, name, reason}}
      end
    else
      {:ok, nil}
    end
  end

  defp encode_metric(_status, _payload, _metric), do: {:ok, nil}

  defp metric_envelope(status, payload, metric, name, metric_type, value, ingress_context) do
    IngressId.put_payload_metadata(
      %{
        "schema" => @metric_schema,
        "source" => "plugin-result",
        "timestamp" => timestamp(payload, status),
        "gateway_id" => status[:gateway_id],
        "agent_id" => status[:agent_id],
        "partition" => status[:partition],
        "metric_name" => name,
        "metric_type" => metric_type,
        "value" => value,
        "unit" => metric_string(metric, ["unit", "u"]),
        "tags" => tags(status, payload),
        "metadata" => metadata(status, payload, metric)
      },
      ingress_context
    )
  end

  defp metric_name(metric) do
    metric
    |> first_present(["name", "metric", "metric_name", "metricName"])
    |> normalize_string()
  end

  defp metric_value(metric) do
    metric
    |> first_present(["value", "val", "metric_value", "metricValue"])
    |> parse_number()
  end

  defp metric_type(metric, metric_name) do
    explicit_type =
      metric
      |> first_present(["metric_type", "metricType", "type", "category"])
      |> normalize_metric_type()

    explicit_type || infer_metric_type(metric, metric_name)
  end

  defp infer_metric_type(metric, metric_name) do
    name = String.downcase(metric_name)
    unit = metric |> metric_string(["unit", "u"]) |> normalize_metric_type()

    cond do
      String.match?(name, ~r/(^|[_\-.])(cpu|processor)([_\-.]|$)/) ->
        "cpu"

      String.match?(name, ~r/(^|[_\-.])(mem|memory|ram)([_\-.]|$)/) ->
        "memory"

      String.match?(name, ~r/(^|[_\-.])(disk|storage|filesystem|fs)([_\-.]|$)/) ->
        "disk"

      String.match?(name, ~r/(^|[_\-.])(interface|network|net|bytes|packets|octets|bandwidth)([_\-.]|$)/) ->
        "interface"

      String.match?(name, ~r/(^|[_\-.])(latency|duration|response_time)([_\-.]|$)/) ->
        "latency"

      unit == "count" or String.ends_with?(name, ["_count", "_total"]) ->
        "count"

      true ->
        "custom"
    end
  end

  defp timestamp(payload, status) do
    Map.get(payload, "observed_at") || Map.get(payload, "observedAt") || status[:agent_timestamp] ||
      status[:timestamp]
  end

  defp tags(status, payload) do
    payload
    |> first_present(["labels", "label"])
    |> normalize_labels()
    |> maybe_put("producer_id", normalize_string(status[:service_name]))
    |> maybe_put("producer_kind", "plugin_result")
    |> maybe_put("service_type", normalize_string(status[:service_type]))
  end

  defp metadata(status, payload, metric) do
    %{}
    |> maybe_put("summary", metric_string(payload, ["summary"]))
    |> maybe_put("status", metric_string(payload, ["status"]))
    |> maybe_put("assignment_id", metric_string(payload, ["assignment_id", "assignmentId"]))
    |> maybe_put("producer_id", normalize_string(status[:service_name]))
    |> maybe_put("producer_kind", "plugin_result")
    |> maybe_put("original_metric_name", metric_string(metric, ["name", "metric", "metric_name", "metricName"]))
    |> maybe_put("service_name", normalize_string(status[:service_name]))
    |> maybe_put("service_type", normalize_string(status[:service_type]))
    |> maybe_put("status_timestamp_unix_nano", status[:timestamp])
    |> maybe_put("agent_timestamp_unix_nano", status[:agent_timestamp])
    |> maybe_put("warn", metric |> first_present(["warn", "warning"]) |> parse_number())
    |> maybe_put("crit", metric |> first_present(["crit", "critical"]) |> parse_number())
    |> maybe_put("min", metric |> first_present(["min"]) |> parse_number())
    |> maybe_put("max", metric |> first_present(["max"]) |> parse_number())
  end

  defp metric_string(map, keys) when is_map(map) do
    map
    |> first_present(keys)
    |> normalize_string()
  end

  defp metric_string(_map, _keys), do: nil

  defp subject(metric_type, metric_name) do
    type = safe_subject_token(metric_type)
    metric = safe_subject_token(metric_name)

    "#{@default_subject_prefix}.#{type || "custom"}.#{metric || "unknown"}"
  end

  defp publish_messages(messages, config) do
    connection = Keyword.get(config, :connection, ServiceRadar.NATS.Connection)
    subject_prefix = Keyword.get(config, :subject_prefix, @default_subject_prefix)
    configured_headers = Keyword.get(config, :headers, [])

    errors =
      Enum.reduce(messages, [], fn {subject, payload, ingress_context}, acc ->
        subject = String.replace_prefix(subject, @default_subject_prefix, subject_prefix)
        headers = configured_headers ++ IngressId.headers(ingress_context)

        case connection.publish(subject, payload, headers: headers) do
          :ok -> acc
          {:error, reason} -> [{subject, reason} | acc]
        end
      end)

    case Enum.reverse(errors) do
      [] -> :ok
      errors -> {:error, {:publish_failed, errors}}
    end
  end

  defp normalize_labels(labels) when is_map(labels) do
    Enum.reduce(labels, %{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), value)
    end)
  end

  defp normalize_labels(_labels), do: %{}

  defp first_present(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp first_present(_map, _keys), do: nil

  defp normalize_string(nil), do: nil
  defp normalize_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_string(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(_value), do: nil

  defp normalize_metric_type(nil), do: nil

  defp normalize_metric_type(value) do
    value
    |> normalize_string()
    |> case do
      nil -> nil
      "" -> nil
      type -> type |> String.downcase() |> String.replace(~r/[^a-z0-9_-]+/, "_")
    end
  end

  defp parse_number(value) when is_number(value), do: value

  defp parse_number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_number(_value), do: nil

  defp safe_subject_token(nil), do: nil

  defp safe_subject_token(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> nil
      token -> token
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp log_publish_error(reason, status, error) do
    Logger.warning("Failed to publish plugin metrics",
      reason: inspect(reason),
      agent_id: status[:agent_id],
      gateway_id: status[:gateway_id],
      partition: status[:partition],
      service_name: status[:service_name]
    )

    error
  end

  defp ingress_context(status) do
    ingress_time = System.system_time(:nanosecond)
    agent_id = status[:agent_id]

    %{
      ingress_time_unix_nano: ingress_time,
      ingress_id: IngressId.new(ingress_time),
      agent_id: agent_id,
      gateway_id: status[:gateway_id],
      partition: status[:partition],
      ingest_identity: if(agent_id, do: "agent:" <> to_string(agent_id))
    }
  end
end
