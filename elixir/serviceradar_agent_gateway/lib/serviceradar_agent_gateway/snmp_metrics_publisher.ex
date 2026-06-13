defmodule ServiceRadarAgentGateway.SnmpMetricsPublisher do
  @moduledoc """
  Publishes SNMP interface metric samples to the high-rate metrics stream.
  """

  alias ServiceRadarAgentGateway.IngressId

  require Logger

  @app :serviceradar_agent_gateway
  @config_key :snmp_metrics_publisher
  @default_subject_prefix "metrics.snmp"
  @interface_octet_metrics ~w(ifHCInOctets ifHCOutOctets)

  @type publish_result :: :ok | :disabled | {:error, term()}

  @spec publish_snmp(map()) :: publish_result()
  def publish_snmp(status) do
    config = config()

    if Keyword.get(config, :enabled, false) do
      do_publish(status, config)
    else
      :disabled
    end
  end

  defp do_publish(status, config) do
    with {:ok, results} <- snmp_results(status),
         {:ok, encoded_messages} <- encode_messages(status, results) do
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

  defp snmp_results(%{message: message}) when is_binary(message) do
    with {:ok, decoded} <- Jason.decode(message),
         results when is_list(results) <- Map.get(decoded, "results") do
      {:ok, results}
    else
      nil -> {:error, :missing_snmp_results}
      {:error, reason} -> {:error, {:invalid_snmp_payload, reason}}
      _other -> {:error, :invalid_snmp_results}
    end
  end

  defp snmp_results(_status), do: {:error, :missing_snmp_message}

  defp encode_messages(status, results) do
    results
    |> Enum.reduce_while({:ok, []}, fn result, {:ok, acc} ->
      case encode_message(status, result) do
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

  defp encode_message(status, result) when is_map(result) do
    with metric_name when metric_name in @interface_octet_metrics <- metric_name(result),
         if_index when is_integer(if_index) and if_index > 0 <- if_index(result),
         value when not is_nil(value) <- Map.get(result, "value"),
         target_device_ip when is_binary(target_device_ip) and target_device_ip != "" <-
           target_device_ip(result) do
      ingress_context = ingress_context(status)
      envelope = metric_envelope(status, result, metric_name, if_index, target_device_ip, value, ingress_context)

      case Jason.encode(envelope) do
        {:ok, encoded} -> {:ok, {subject(metric_name), encoded, ingress_context}}
        {:error, reason} -> {:error, {:encode_failed, metric_name, reason}}
      end
    else
      _skip -> {:ok, nil}
    end
  end

  defp encode_message(_status, _result), do: {:ok, nil}

  defp metric_envelope(status, result, metric_name, if_index, target_device_ip, value, ingress_context) do
    IngressId.put_payload_metadata(
      %{
        "schema" => "serviceradar.snmp.interface_metric.v1",
        "source" => "snmp-metrics",
        "timestamp" => Map.get(result, "timestamp") || status[:agent_timestamp] || status[:timestamp],
        "gateway_id" => status[:gateway_id],
        "agent_id" => status[:agent_id],
        "partition" => status[:partition],
        "metric_name" => metric_name,
        "metric_type" => "snmp",
        "value" => value,
        "raw_value" => Map.get(result, "raw_value") || Map.get(result, "rawValue"),
        "unit" => Map.get(result, "unit"),
        "scale" => Map.get(result, "scale"),
        "is_delta" => Map.get(result, "delta") || Map.get(result, "is_delta") || false,
        "kind" => Map.get(result, "kind"),
        "temporality" => Map.get(result, "temporality"),
        "is_monotonic" => Map.get(result, "is_monotonic") || Map.get(result, "isMonotonic"),
        "counter_width" => Map.get(result, "counter_width") || Map.get(result, "counterWidth"),
        "target_device_ip" => target_device_ip,
        "if_index" => if_index,
        "tags" => tags(result, target_device_ip, metric_name),
        "metadata" => metadata(status, result)
      },
      ingress_context
    )
  end

  defp metric_name(result) do
    result
    |> first_present(["metric", "metric_name", "metricName", "name"])
    |> normalize_string()
    |> normalize_metric_name()
  end

  defp normalize_metric_name(nil), do: nil

  defp normalize_metric_name(metric_name) do
    metric_name
    |> String.split("::", parts: 2)
    |> List.first()
  end

  defp if_index(result) do
    result
    |> first_present(["if_index", "ifIndex", "interface_index", "interfaceIndex"])
    |> parse_int()
  end

  defp target_device_ip(result) do
    result
    |> first_present(["host_ip", "hostIp", "host", "target_device_ip", "targetDeviceIp", "ip"])
    |> normalize_string()
  end

  defp tags(result, target_device_ip, metric_name) do
    %{
      "target" => target_device_ip,
      "metric" => metric_name
    }
    |> maybe_put("target_name", normalize_string(Map.get(result, "target")))
    |> maybe_put("interface_uid", normalize_string(Map.get(result, "interface_uid") || Map.get(result, "interfaceUid")))
  end

  defp metadata(status, result) do
    %{}
    |> maybe_put(
      "oid",
      normalize_string(Map.get(result, "oid") || Map.get(result, "oid_name") || Map.get(result, "oidName"))
    )
    |> maybe_put("data_type", normalize_string(Map.get(result, "data_type") || Map.get(result, "dataType")))
    |> maybe_put("kind", normalize_string(Map.get(result, "kind")))
    |> maybe_put("temporality", normalize_string(Map.get(result, "temporality")))
    |> maybe_put("is_monotonic", Map.get(result, "is_monotonic") || Map.get(result, "isMonotonic"))
    |> maybe_put("counter_width", Map.get(result, "counter_width") || Map.get(result, "counterWidth"))
    |> maybe_put("raw_value", Map.get(result, "raw_value") || Map.get(result, "rawValue"))
    |> maybe_put("interface_uid", normalize_string(Map.get(result, "interface_uid") || Map.get(result, "interfaceUid")))
    |> maybe_put("status_timestamp_unix_nano", status[:timestamp])
    |> maybe_put("agent_timestamp_unix_nano", status[:agent_timestamp])
    |> maybe_put("service_name", status[:service_name])
    |> maybe_put("service_type", status[:service_type])
  end

  defp subject(metric_name), do: "#{@default_subject_prefix}.interface.#{metric_name}"

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

  defp first_present(map, keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp normalize_string(nil), do: nil
  defp normalize_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_string(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(_value), do: nil

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp parse_int(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp log_publish_error(reason, status, error) do
    Logger.warning("Failed to publish SNMP metrics",
      reason: inspect(reason),
      agent_id: status[:agent_id],
      gateway_id: status[:gateway_id],
      partition: status[:partition]
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
