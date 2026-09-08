defmodule ServiceRadarAgentGateway.OtlpRelayPublisher do
  @moduledoc """
  Publishes agent-relayed OTLP protobuf chunks to the local JetStream ingress.

  Agent relays already spool and chunk OTLP payloads before they reach the
  gateway. The gateway is the authenticated edge ingress point, so it stamps
  attribution headers from the mTLS-derived status metadata and publishes each
  record verbatim to the canonical telemetry subject.
  """

  alias Serviceradar.Agent.Addon.V1.TelemetryBatch
  alias Serviceradar.Agent.Addon.V1.TelemetryCounters
  alias Serviceradar.Agent.Addon.V1.TelemetryRecord
  alias ServiceRadar.EventWriter.SignalTelemetry
  alias ServiceRadarAgentGateway.IngressId

  require Logger

  @app :serviceradar_agent_gateway
  @config_key :otlp_relay_publisher
  @telemetry_otlp_relay_spool [:serviceradar, :otlp_relay, :spool]
  @telemetry_otlp_relay_rejected [:serviceradar, :otlp_relay, :record_rejected]

  @type publish_result :: :ok | :disabled | {:error, term()}

  @spec publish_relay(map()) :: publish_result()
  def publish_relay(status) do
    config = config()

    if Keyword.get(config, :enabled, false) do
      do_publish(status, config)
    else
      :disabled
    end
  end

  defp config do
    Application.get_env(@app, @config_key, [])
  end

  defp do_publish(status, config) do
    partition_id = status[:partition] || "default"
    agent_id = to_string(status[:agent_id] || "")
    metadata = %{partition_id: partition_id, agent_id: agent_id, gateway_id: status[:gateway_id]}

    case decode_batch(status[:message]) do
      {:ok, %TelemetryBatch{} = batch} ->
        emit_spool_counters(batch.counters, partition_id, agent_id)

        publish_records(
          batch.records || [],
          base_headers(partition_id, agent_id, status[:gateway_id]),
          metadata,
          config
        )

      :error ->
        Logger.warning(
          "AgentGateway: failed to decode otlp-relay TelemetryBatch",
          partition_id: partition_id,
          agent_id: agent_id,
          message_size: byte_size_or_nil(status[:message])
        )

        {:error, :otlp_relay_decode_failed}
    end
  end

  defp decode_batch(message) when is_binary(message) do
    {:ok, TelemetryBatch.decode(message)}
  rescue
    _ -> :error
  end

  defp decode_batch(_message), do: :error

  defp base_headers(partition_id, agent_id, gateway_id) do
    Enum.reject(
      [
        {"Sr-Agent-Id", agent_id},
        {"Sr-Gateway-Id", to_string(gateway_id || "")},
        {"Sr-Partition", partition_id},
        {"Sr-Ingest-Identity", "agent:" <> agent_id}
      ],
      fn {_key, value} -> value == "" end
    )
  end

  defp publish_records(records, base_headers, metadata, config) do
    connection = Keyword.get(config, :connection, ServiceRadar.NATS.Connection)
    subjects = subjects(config)

    Enum.reduce_while(records, :ok, fn %TelemetryRecord{} = record, :ok ->
      publish_record(connection, subjects, record, base_headers, metadata)
    end)
  end

  defp publish_record(connection, subjects, %TelemetryRecord{} = record, base_headers, metadata) do
    case route(record.payload_kind, subjects) do
      {:ok, subject, signal} ->
        ingress_time = System.system_time(:nanosecond)
        ingress_id = IngressId.new(ingress_time)

        headers =
          base_headers ++
            IngressId.headers(%{
              ingress_id: ingress_id,
              ingress_time_unix_nano: ingress_time
            })

        case connection.publish(subject, record.payload, headers: headers) do
          :ok ->
            SignalTelemetry.emit(signal, :relayed, 1)
            {:cont, :ok}

          {:error, reason} ->
            log_publish_failure(subject, reason, metadata)
            {:halt, {:error, {:otlp_relay_publish_failed, reason}}}
        end

      :error ->
        :telemetry.execute(@telemetry_otlp_relay_rejected, %{count: 1}, metadata)

        Logger.warning(
          "AgentGateway: dropping otlp-relay record with unroutable payload kind",
          payload_kind: inspect(record.payload_kind),
          event_id: record.event_id,
          partition_id: metadata.partition_id,
          agent_id: metadata.agent_id
        )

        {:cont, :ok}
    end
  end

  defp subjects(config) do
    [
      traces: Keyword.get(config, :traces_subject, "otel.traces.raw"),
      logs: Keyword.get(config, :logs_subject, "logs.otel"),
      metrics: Keyword.get(config, :metrics_subject, "otel.metrics.raw"),
      derived_metrics: Keyword.get(config, :derived_metrics_subject, "otel.metrics.derived")
    ]
  end

  defp route(kind, subjects) when kind in [:TELEMETRY_PAYLOAD_KIND_OTLP_TRACES, 3], do: {:ok, subjects[:traces], :traces}

  defp route(kind, subjects) when kind in [:TELEMETRY_PAYLOAD_KIND_OTLP_LOGS, 4], do: {:ok, subjects[:logs], :logs}

  defp route(kind, subjects) when kind in [:TELEMETRY_PAYLOAD_KIND_OTLP_METRICS, 5],
    do: {:ok, subjects[:metrics], :metric_points}

  defp route(kind, subjects) when kind in [:TELEMETRY_PAYLOAD_KIND_OTLP_DERIVED_METRIC, 6],
    do: {:ok, subjects[:derived_metrics], :metrics}

  defp route(_kind, _subjects), do: :error

  defp emit_spool_counters(%TelemetryCounters{} = counters, partition_id, agent_id) do
    :telemetry.execute(
      @telemetry_otlp_relay_spool,
      %{
        received: counters.received || 0,
        filtered: counters.filtered || 0,
        emitted: counters.emitted || 0,
        dropped: counters.dropped || 0,
        queue_depth: counters.queue_depth || 0
      },
      %{partition_id: partition_id, agent_id: agent_id}
    )
  end

  defp emit_spool_counters(_counters, _partition_id, _agent_id), do: :ok

  defp log_publish_failure(subject, reason, metadata) do
    Logger.warning(
      "AgentGateway: failed to publish otlp-relay record",
      subject: subject,
      reason: inspect(reason),
      partition_id: metadata.partition_id,
      agent_id: metadata.agent_id
    )
  end

  defp byte_size_or_nil(message) when is_binary(message), do: byte_size(message)
  defp byte_size_or_nil(_message), do: nil
end
