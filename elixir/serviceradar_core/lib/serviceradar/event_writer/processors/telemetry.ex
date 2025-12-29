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
    "poller_id": "poller-1",
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
    poller_id TEXT NOT NULL,
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

  require Logger

  @impl true
  def table_name, do: "timeseries_metrics"

  @impl true
  def process_batch(messages) do
    rows =
      messages
      |> Enum.map(&parse_message/1)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(rows) do
      {:ok, 0}
    else
      case ServiceRadar.Repo.insert_all(table_name(), rows,
             on_conflict: :nothing,
             returning: false
           ) do
        {count, _} ->
          {:ok, count}
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
    timestamp = parse_timestamp(json["timestamp"])

    %{
      timestamp: timestamp,
      poller_id: json["poller_id"] || json["pollerId"] || "unknown",
      agent_id: json["agent_id"] || json["agentId"],
      metric_name: json["metric_name"] || json["metricName"] || json["name"] || "unknown",
      metric_type: json["metric_type"] || json["metricType"] || json["type"] || "gauge",
      device_id: json["device_id"] || json["deviceId"],
      value: parse_value(json["value"]),
      unit: json["unit"],
      tags: encode_jsonb(json["tags"]),
      partition: json["partition"],
      scale: json["scale"],
      is_delta: json["is_delta"] || json["isDelta"] || false,
      target_device_ip: json["target_device_ip"] || json["targetDeviceIp"],
      if_index: json["if_index"] || json["ifIndex"],
      metadata: encode_jsonb(json["metadata"]),
      created_at: DateTime.utc_now()
    }
  end

  defp parse_timestamp(nil), do: DateTime.utc_now()
  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end
  defp parse_timestamp(ts) when is_integer(ts) do
    if ts > 1_000_000_000_000 do
      DateTime.from_unix!(ts, :millisecond)
    else
      DateTime.from_unix!(ts, :second)
    end
  end
  defp parse_timestamp(_), do: DateTime.utc_now()

  defp parse_value(nil), do: 0.0
  defp parse_value(v) when is_number(v), do: v
  defp parse_value(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0.0
    end
  end
  defp parse_value(_), do: 0.0

  defp encode_jsonb(nil), do: nil
  defp encode_jsonb(value) when is_map(value), do: value
  defp encode_jsonb(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> nil
    end
  end
  defp encode_jsonb(_), do: nil
end
