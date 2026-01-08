defmodule ServiceRadar.EventWriter.Processors.Telemetry do
  @moduledoc """
  Processor for telemetry metrics messages.

  Parses telemetry metrics from NATS JetStream and inserts them into
  the `timeseries_metrics` hypertable.

  ## Message Format

  JSON telemetry messages with metric data:

  ```json
  {
    "timestamp": "2024-01-01T00:00:00Z",
    "gateway_id": "gateway-1",
    "agent_id": "agent-1",
    "metric_name": "cpu_usage",
    "metric_type": "gauge",
    "device_id": "device-1",
    "value": 45.5,
    "unit": "percent",
    "tags": {"host": "server1"}
  }
  ```

  ## Table Schema

  ```sql
  CREATE TABLE timeseries_metrics (
    timestamp TIMESTAMPTZ NOT NULL,
    gateway_id TEXT NOT NULL,
    agent_id TEXT,
    metric_name TEXT NOT NULL,
    metric_type TEXT NOT NULL,
    device_id TEXT,
    value DOUBLE PRECISION NOT NULL,
    unit TEXT,
    tags JSONB,
    partition TEXT,
    scale DOUBLE PRECISION,
    is_delta BOOLEAN DEFAULT FALSE,
    target_device_ip TEXT,
    if_index INTEGER,
    metadata JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
  );
  ```
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.EventWriter.TenantContext

  require Logger

  @impl true
  def table_name, do: "timeseries_metrics"

  @impl true
  def process_batch(messages) do
    schema = TenantContext.current_schema()

    if is_nil(schema) do
      Logger.error("Telemetry batch missing tenant schema context")
      {:error, :missing_tenant_schema}
    else
      rows =
        messages
        |> Enum.map(&parse_message/1)
        |> Enum.reject(&is_nil/1)

      if Enum.empty?(rows) do
        {:ok, 0}
      else
        case ServiceRadar.Repo.insert_all(table_name(), rows,
               prefix: schema,
               on_conflict: :nothing,
               returning: false
             ) do
          {count, _} ->
            {:ok, count}
        end
      end
    end
  rescue
    e ->
      Logger.error("Telemetry batch insert failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(%{data: data, metadata: _metadata}) do
    case Jason.decode(data) do
      {:ok, json} ->
        parse_telemetry(json)

      {:error, _} ->
        Logger.debug("Failed to parse telemetry message as JSON")
        nil
    end
  end

  # Private functions

  defp parse_telemetry(json) do
    timestamp = FieldParser.parse_timestamp(json["timestamp"])

    %{
      timestamp: timestamp,
      gateway_id: FieldParser.get_field(json, "gateway_id", "gatewayId", "unknown"),
      agent_id: FieldParser.get_field(json, "agent_id", "agentId"),
      metric_name: FieldParser.get_field(json, "metric_name", "metricName") || json["name"] || "unknown",
      metric_type: FieldParser.get_field(json, "metric_type", "metricType") || json["type"] || "gauge",
      device_id: FieldParser.get_field(json, "device_id", "deviceId"),
      value: FieldParser.parse_value(json["value"]),
      unit: json["unit"],
      tags: FieldParser.encode_jsonb(json["tags"]),
      partition: json["partition"],
      scale: json["scale"],
      is_delta: FieldParser.get_field(json, "is_delta", "isDelta", false),
      target_device_ip: FieldParser.get_field(json, "target_device_ip", "targetDeviceIp"),
      if_index: FieldParser.get_field(json, "if_index", "ifIndex"),
      metadata: FieldParser.encode_jsonb(json["metadata"]),
      created_at: DateTime.utc_now()
    }
  end
end
