defmodule ServiceRadarAgentGateway.SysmonMetricsPublisher do
  @moduledoc """
  Publishes sysmon metric samples to the high-rate metrics stream.
  """

  alias ServiceRadarAgentGateway.IngressId

  require Logger

  @app :serviceradar_agent_gateway
  @config_key :sysmon_metrics_publisher
  @default_subject_prefix "metrics.sysmon"

  @type publish_result :: :ok | :disabled | {:error, term()}

  @spec publish_sysmon(map()) :: publish_result()
  def publish_sysmon(status) do
    config = config()

    if Keyword.get(config, :enabled, false) do
      do_publish(status, config)
    else
      :disabled
    end
  end

  defp do_publish(status, config) do
    with {:ok, sample} <- sysmon_sample(status),
         families when families != [] <- metric_families(sample),
         {:ok, encoded_messages} <- encode_messages(status, sample, families) do
      publish_messages(encoded_messages, config)
    else
      [] -> :ok
      {:error, reason} = error -> log_publish_error(reason, status, error)
    end
  end

  defp config do
    Application.get_env(@app, @config_key, [])
  end

  defp sysmon_sample(%{message: message}) when is_binary(message) do
    with {:ok, decoded} <- Jason.decode(message),
         %{} = sample <- Map.get(decoded, "status") do
      {:ok, sample}
    else
      nil -> {:error, :missing_sysmon_status}
      {:error, reason} -> {:error, {:invalid_sysmon_payload, reason}}
      _other -> {:error, :invalid_sysmon_status}
    end
  end

  defp sysmon_sample(_status), do: {:error, :missing_sysmon_message}

  defp metric_families(sample) do
    []
    |> maybe_add_family("cpu", has_non_empty_list?(sample, "cpus") or has_non_empty_list?(sample, "clusters"))
    |> maybe_add_family("memory", populated_memory?(Map.get(sample, "memory")))
    |> maybe_add_family("disk", has_non_empty_list?(sample, "disks"))
    |> maybe_add_family("process", has_non_empty_list?(sample, "processes"))
  end

  defp maybe_add_family(families, family, true), do: [family | families]
  defp maybe_add_family(families, _family, false), do: families

  defp has_non_empty_list?(sample, key) do
    case Map.get(sample, key) do
      [_ | _] -> true
      _ -> false
    end
  end

  defp populated_memory?(%{} = memory) do
    Enum.any?(["used_bytes", "total_bytes", "swap_used_bytes", "swap_total_bytes"], fn key ->
      case Map.get(memory, key) do
        value when is_integer(value) -> value > 0
        value when is_float(value) -> value > 0
        _ -> false
      end
    end)
  end

  defp populated_memory?(_memory), do: false

  defp encode_messages(status, sample, families) do
    base = base_envelope(status, sample)

    families
    |> Enum.reverse()
    |> Enum.reduce_while({:ok, []}, fn family, {:ok, acc} ->
      ingress_context = ingress_context(status)

      envelope =
        base
        |> Map.put("metric_family", family)
        |> IngressId.put_payload_metadata(ingress_context)

      case Jason.encode(envelope) do
        {:ok, encoded} -> {:cont, {:ok, [{family, encoded, ingress_context} | acc]}}
        {:error, reason} -> {:halt, {:error, {:encode_failed, family, reason}}}
      end
    end)
    |> case do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      error -> error
    end
  end

  defp base_envelope(status, sample) do
    %{
      "schema" => "serviceradar.sysmon.metrics.v1",
      "source" => "sysmon-metrics",
      "agent_id" => status[:agent_id],
      "gateway_id" => status[:gateway_id],
      "partition" => status[:partition],
      "service_name" => status[:service_name],
      "service_type" => status[:service_type],
      "status_timestamp_unix_nano" => status[:timestamp],
      "agent_timestamp_unix_nano" => status[:agent_timestamp],
      "received_at_unix_nano" => System.system_time(:nanosecond),
      "sample" => sample
    }
  end

  defp publish_messages(messages, config) do
    connection = Keyword.get(config, :connection, ServiceRadar.NATS.Connection)
    subject_prefix = Keyword.get(config, :subject_prefix, @default_subject_prefix)
    configured_headers = Keyword.get(config, :headers, [])

    errors =
      Enum.reduce(messages, [], fn {family, payload, ingress_context}, acc ->
        subject = "#{subject_prefix}.#{family}"
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

  defp log_publish_error(reason, status, error) do
    Logger.warning("Failed to publish sysmon metrics",
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
