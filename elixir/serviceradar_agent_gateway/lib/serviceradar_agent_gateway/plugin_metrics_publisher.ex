defmodule ServiceRadarAgentGateway.PluginMetricsPublisher do
  @moduledoc """
  Publishes first-class plugin/add-on metric telemetry to the high-rate metrics stream.
  """

  alias Serviceradar.Agent.Addon.V1.TelemetryBatch
  alias Serviceradar.Agent.Addon.V1.TelemetryCounters
  alias Serviceradar.Agent.Addon.V1.TelemetryRecord
  alias Serviceradar.Metric.V1.MetricBatch
  alias ServiceRadarAgentGateway.IngressId
  alias ServiceRadarAgentGateway.MetricEnvelopeAttestation

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
    with {:ok, batch} <- decode_telemetry_batch(status[:message]),
         {:ok, messages} <- metric_messages(status, batch) do
      case messages do
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

  defp decode_telemetry_batch(message) when is_binary(message) do
    {:ok, TelemetryBatch.decode(message)}
  rescue
    _ -> {:error, :invalid_plugin_metric_telemetry}
  end

  defp decode_telemetry_batch(_message), do: {:error, :missing_plugin_message}

  defp metric_messages(status, %TelemetryBatch{} = batch) do
    emit_spool_counters(batch.counters, status)

    batch.records
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, acc} ->
      case metric_message(status, record) do
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

  defp metric_message(status, %TelemetryRecord{} = record) do
    if metric_payload_kind?(record.payload_kind) do
      with {:ok, %MetricBatch{} = batch} <- decode_metric_batch(record.payload),
           :ok <- validate_metric_batch(batch) do
        ingress_context = ingress_context(status, record)

        batch =
          MetricEnvelopeAttestation.attest(batch, status, ingress_context,
            source: attested_source(status),
            producer_id: status[:service_name],
            producer_kind: attested_producer_kind(status)
          )

        {:ok, {subject(batch), MetricBatch.encode(batch), ingress_context}}
      end
    else
      {:ok, nil}
    end
  end

  defp metric_message(_status, _record), do: {:ok, nil}

  defp metric_payload_kind?(:TELEMETRY_PAYLOAD_KIND_SERVICERADAR_METRICS), do: true
  defp metric_payload_kind?(7), do: true
  defp metric_payload_kind?(_kind), do: false

  defp decode_metric_batch(payload) when is_binary(payload) do
    {:ok, MetricBatch.decode(payload)}
  rescue
    _ -> {:error, :invalid_metric_batch_payload}
  end

  defp validate_metric_batch(%MetricBatch{schema_version: @metric_schema, metrics: [_ | _]}), do: :ok

  defp validate_metric_batch(_batch), do: {:error, :invalid_metric_batch_schema}

  defp subject(%MetricBatch{metrics: [metric | _]}) do
    metric_type = normalize_string(metric.metric_type) || "custom"
    metric_name = normalize_string(metric.name) || "unknown"
    type = safe_subject_token(metric_type)
    metric = safe_subject_token(metric_name)

    "#{@default_subject_prefix}.#{type || "custom"}.#{metric || "unknown"}"
  end

  defp subject(_batch), do: "#{@default_subject_prefix}.custom.unknown"

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

  defp normalize_string(nil), do: nil
  defp normalize_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_string(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(_value), do: nil

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

  defp ingress_context(status, record) do
    ingress_time = System.system_time(:nanosecond)
    agent_id = status[:agent_id]

    %{
      ingress_time_unix_nano: ingress_time,
      ingress_id: IngressId.new(ingress_time),
      event_id: record.event_id,
      event_time_unix_nano: record.event_time_unix_nano,
      observed_time_unix_nano: record.observed_time_unix_nano,
      agent_id: agent_id,
      gateway_id: status[:gateway_id],
      partition: status[:partition],
      ingest_identity: if(agent_id, do: "agent:" <> to_string(agent_id))
    }
  end

  defp emit_spool_counters(%TelemetryCounters{} = counters, status) do
    :telemetry.execute(
      [:serviceradar, :plugin_metrics, :spool],
      %{
        received: counters.received || 0,
        filtered: counters.filtered || 0,
        emitted: counters.emitted || 0,
        dropped: counters.dropped || 0,
        queue_depth: counters.queue_depth || 0
      },
      %{
        partition: status[:partition],
        agent_id: status[:agent_id],
        gateway_id: status[:gateway_id],
        service_name: status[:service_name]
      }
    )
  end

  defp emit_spool_counters(_counters, _status), do: :ok

  defp attested_source(%{source: source}) when is_binary(source) do
    cond do
      String.starts_with?(source, "addon:") -> "native-addon"
      String.starts_with?(source, "plugin:") -> "wasm-plugin"
      true -> source
    end
  end

  defp attested_source(%{service_type: service_type}) when service_type in ["native-addon", :native_addon],
    do: "native-addon"

  defp attested_source(%{service_type: service_type}) when service_type in ["wasm-plugin", :wasm_plugin],
    do: "wasm-plugin"

  defp attested_source(_status), do: "plugin"

  defp attested_producer_kind(%{service_type: service_type}) when service_type in ["native-addon", :native_addon],
    do: "native-addon"

  defp attested_producer_kind(%{service_type: service_type}) when service_type in ["wasm-plugin", :wasm_plugin],
    do: "wasm-plugin"

  defp attested_producer_kind(status), do: status[:service_type] || "plugin"
end
