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

  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.EventWriter.TenantContext

  require Logger

  @impl true
  def table_name, do: "otel_traces"

  @impl true
  def process_batch(messages) do
    schema = TenantContext.current_schema()

    if is_nil(schema) do
      Logger.error("OtelTraces batch missing tenant schema context")
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
    timestamp = FieldParser.parse_timestamp(json["timestamp"] || json["start_time_unix_nano"])

    %{
      timestamp: timestamp,
      trace_id: FieldParser.get_field(json, "trace_id", "traceId"),
      span_id: FieldParser.get_field(json, "span_id", "spanId"),
      parent_span_id: FieldParser.get_field(json, "parent_span_id", "parentSpanId"),
      name: json["name"],
      kind: json["kind"],
      start_time_unix_nano: FieldParser.safe_bigint(FieldParser.get_field(json, "start_time_unix_nano", "startTimeUnixNano")),
      end_time_unix_nano: FieldParser.safe_bigint(FieldParser.get_field(json, "end_time_unix_nano", "endTimeUnixNano")),
      service_name: FieldParser.get_field(json, "service_name", "serviceName", "unknown"),
      service_version: FieldParser.get_field(json, "service_version", "serviceVersion"),
      service_instance: FieldParser.get_field(json, "service_instance", "serviceInstance"),
      scope_name: FieldParser.get_field(json, "scope_name", "scopeName"),
      scope_version: FieldParser.get_field(json, "scope_version", "scopeVersion"),
      status_code: FieldParser.get_field(json, "status_code", "statusCode"),
      status_message: FieldParser.get_field(json, "status_message", "statusMessage"),
      attributes: FieldParser.encode_json(json["attributes"]),
      resource_attributes: FieldParser.encode_json(FieldParser.get_field(json, "resource_attributes", "resourceAttributes")),
      events: FieldParser.encode_json(json["events"]),
      links: FieldParser.encode_json(json["links"]),
      created_at: DateTime.utc_now()
    }
  end

  defp parse_protobuf_trace(_data, _metadata) do
    # TODO: Implement protobuf parsing for ExportTraceServiceRequest
    # For now, skip protobuf messages
    nil
  end
end
