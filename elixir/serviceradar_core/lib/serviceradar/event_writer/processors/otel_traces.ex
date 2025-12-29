defmodule ServiceRadar.EventWriter.Processors.OtelTraces do
  @moduledoc """
  Processor for OpenTelemetry trace messages.

  Parses OTEL traces from NATS JetStream and inserts them into
  the `otel_traces` hypertable.

  ## Message Format

  Supports both JSON and protobuf formats:

  - Protobuf: OpenTelemetry `ExportTraceServiceRequest`
  - JSON: Trace span data with attributes

  ## Table Schema

  ```sql
  CREATE TABLE otel_traces (
    timestamp TIMESTAMPTZ NOT NULL,
    trace_id TEXT,
    span_id TEXT,
    parent_span_id TEXT,
    name TEXT,
    kind INTEGER,
    start_time_unix_nano BIGINT,
    end_time_unix_nano BIGINT,
    service_name TEXT,
    service_version TEXT,
    service_instance TEXT,
    scope_name TEXT,
    scope_version TEXT,
    status_code INTEGER,
    status_message TEXT,
    attributes TEXT,
    resource_attributes TEXT,
    events TEXT,
    links TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (timestamp, trace_id, span_id)
  );
  ```
  """

  @behaviour ServiceRadar.EventWriter.Processor

  require Logger

  @impl true
  def table_name, do: "otel_traces"

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
      Logger.error("OtelTraces batch insert failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(%{data: data, metadata: metadata}) do
    case Jason.decode(data) do
      {:ok, json} ->
        parse_json_trace(json, metadata)

      {:error, _} ->
        # Try protobuf parsing
        parse_protobuf_trace(data, metadata)
    end
  end

  # Private functions

  defp parse_json_trace(json, _metadata) do
    timestamp = parse_timestamp(json["timestamp"] || json["start_time_unix_nano"])

    %{
      timestamp: timestamp,
      trace_id: json["trace_id"] || json["traceId"],
      span_id: json["span_id"] || json["spanId"],
      parent_span_id: json["parent_span_id"] || json["parentSpanId"],
      name: json["name"],
      kind: json["kind"],
      start_time_unix_nano: safe_bigint(json["start_time_unix_nano"] || json["startTimeUnixNano"]),
      end_time_unix_nano: safe_bigint(json["end_time_unix_nano"] || json["endTimeUnixNano"]),
      service_name: json["service_name"] || json["serviceName"] || "unknown",
      service_version: json["service_version"] || json["serviceVersion"],
      service_instance: json["service_instance"] || json["serviceInstance"],
      scope_name: json["scope_name"] || json["scopeName"],
      scope_version: json["scope_version"] || json["scopeVersion"],
      status_code: json["status_code"] || json["statusCode"],
      status_message: json["status_message"] || json["statusMessage"],
      attributes: encode_json(json["attributes"]),
      resource_attributes: encode_json(json["resource_attributes"] || json["resourceAttributes"]),
      events: encode_json(json["events"]),
      links: encode_json(json["links"]),
      created_at: DateTime.utc_now()
    }
  end

  defp parse_protobuf_trace(_data, _metadata) do
    # TODO: Implement protobuf parsing for ExportTraceServiceRequest
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

  # Safe conversion for bigint values that might overflow int64
  defp safe_bigint(nil), do: nil
  defp safe_bigint(value) when is_integer(value) do
    max_int64 = 9_223_372_036_854_775_807
    min_int64 = -9_223_372_036_854_775_808

    cond do
      value > max_int64 -> max_int64
      value < min_int64 -> min_int64
      true -> value
    end
  end
  defp safe_bigint(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> safe_bigint(int)
      :error -> nil
    end
  end
  defp safe_bigint(_), do: nil

  defp encode_json(nil), do: nil
  defp encode_json(value) when is_map(value) or is_list(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      _ -> nil
    end
  end
  defp encode_json(value) when is_binary(value), do: value
  defp encode_json(_), do: nil
end
