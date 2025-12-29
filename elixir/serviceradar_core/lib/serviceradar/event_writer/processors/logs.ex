defmodule ServiceRadar.EventWriter.Processors.Logs do
  @moduledoc """
  Processor for OpenTelemetry log messages.

  Parses OTEL logs from NATS JetStream and inserts them into
  the `logs` hypertable.

  ## Message Format

  Supports both JSON and protobuf formats:

  - Protobuf: OpenTelemetry `ExportLogsServiceRequest`
  - JSON: Structured log data with attributes

  ## Table Schema

  ```sql
  CREATE TABLE logs (
    timestamp TIMESTAMPTZ NOT NULL,
    trace_id TEXT,
    span_id TEXT,
    severity_text TEXT,
    severity_number INTEGER,
    body TEXT,
    service_name TEXT,
    service_version TEXT,
    service_instance TEXT,
    scope_name TEXT,
    scope_version TEXT,
    attributes TEXT,
    resource_attributes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (timestamp, trace_id, span_id)
  );
  ```
  """

  @behaviour ServiceRadar.EventWriter.Processor

  require Logger

  @impl true
  def table_name, do: "logs"

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
      Logger.error("Logs batch insert failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(%{data: data, metadata: metadata}) do
    case Jason.decode(data) do
      {:ok, json} ->
        parse_json_log(json, metadata)

      {:error, _} ->
        # Try protobuf parsing
        parse_protobuf_log(data, metadata)
    end
  end

  # Private functions

  defp parse_json_log(json, _metadata) do
    timestamp = parse_timestamp(json["timestamp"] || json["time_unix_nano"])

    # Generate trace_id and span_id if not provided (required for PK)
    trace_id = json["trace_id"] || json["traceId"] || generate_id()
    span_id = json["span_id"] || json["spanId"] || generate_id()

    %{
      timestamp: timestamp,
      trace_id: trace_id,
      span_id: span_id,
      severity_text: json["severity_text"] || json["severityText"] || json["level"],
      severity_number: json["severity_number"] || json["severityNumber"],
      body: extract_body(json),
      service_name: json["service_name"] || json["serviceName"] || "unknown",
      service_version: json["service_version"] || json["serviceVersion"],
      service_instance: json["service_instance"] || json["serviceInstance"],
      scope_name: json["scope_name"] || json["scopeName"],
      scope_version: json["scope_version"] || json["scopeVersion"],
      attributes: encode_json(json["attributes"]),
      resource_attributes: encode_json(json["resource_attributes"] || json["resourceAttributes"]),
      created_at: DateTime.utc_now()
    }
  end

  defp parse_protobuf_log(_data, _metadata) do
    # TODO: Implement protobuf parsing for ExportLogsServiceRequest
    # For now, skip protobuf messages
    nil
  end

  defp parse_timestamp(nil), do: DateTime.utc_now()
  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end
  defp parse_timestamp(ts) when is_integer(ts) do
    # Handle nanoseconds timestamp
    if ts > 1_000_000_000_000_000_000 do
      DateTime.from_unix!(div(ts, 1_000_000_000), :second)
    else
      DateTime.from_unix!(ts, :millisecond)
    end
  end
  defp parse_timestamp(_), do: DateTime.utc_now()

  defp extract_body(json) do
    cond do
      is_binary(json["body"]) -> json["body"]
      is_map(json["body"]) -> Jason.encode!(json["body"])
      json["message"] -> json["message"]
      json["msg"] -> json["msg"]
      json["short_message"] -> json["short_message"]
      true -> nil
    end
  end

  defp encode_json(nil), do: nil
  defp encode_json(value) when is_map(value) or is_list(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      _ -> nil
    end
  end
  defp encode_json(value) when is_binary(value), do: value
  defp encode_json(_), do: nil

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
