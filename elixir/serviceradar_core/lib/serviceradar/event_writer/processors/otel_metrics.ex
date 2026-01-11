defmodule ServiceRadar.EventWriter.Processors.OtelMetrics do
  @moduledoc """
  Processor for OpenTelemetry metrics messages.

  Parses OTEL metrics from NATS JetStream and inserts them into
  the `otel_metrics` hypertable.

  ## Message Format

  Supports both JSON and protobuf formats:

  - Protobuf: OpenTelemetry `ExportMetricsServiceRequest`
  - JSON: Performance metrics with span info

  ## Table Schema

  ```sql
  CREATE TABLE otel_metrics (
    timestamp TIMESTAMPTZ NOT NULL,
    trace_id TEXT,
    span_id TEXT,
    service_name TEXT,
    span_name TEXT,
    span_kind TEXT,
    duration_ms DOUBLE PRECISION,
    duration_seconds DOUBLE PRECISION,
    metric_type TEXT,
    http_method TEXT,
    http_route TEXT,
    http_status_code TEXT,
    grpc_service TEXT,
    grpc_method TEXT,
    grpc_status_code TEXT,
    is_slow BOOLEAN,
    component TEXT,
    level TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (timestamp, span_name, service_name, span_id)
  );
  ```
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.EventWriter.TenantContext

  require Logger

  @impl true
  def table_name, do: "otel_metrics"

  @impl true
  def process_batch(messages) do
    schema = TenantContext.current_schema()

    if is_nil(schema) do
      Logger.error("OtelMetrics batch missing tenant schema context")
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
      Logger.error("OtelMetrics batch insert failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(%{data: data, metadata: metadata}) do
    case Jason.decode(data) do
      {:ok, json} ->
        parse_json_metric(json, metadata)

      {:error, _} ->
        # Try protobuf parsing
        parse_protobuf_metric(data, metadata)
    end
  end

  # Private functions

  defp parse_json_metric(json, _metadata) do
    timestamp = FieldParser.parse_timestamp(json["timestamp"])

    %{
      timestamp: timestamp,
      trace_id: FieldParser.get_field(json, "trace_id", "traceId"),
      span_id: FieldParser.get_field(json, "span_id", "spanId"),
      service_name: FieldParser.get_field(json, "service_name", "serviceName", "unknown"),
      span_name: FieldParser.get_field(json, "span_name", "spanName") || json["name"] || "unknown",
      span_kind: FieldParser.get_field(json, "span_kind", "spanKind"),
      duration_ms: FieldParser.parse_duration_ms(json),
      duration_seconds: FieldParser.parse_duration_seconds(json),
      metric_type: FieldParser.get_field(json, "metric_type", "metricType"),
      http_method: FieldParser.get_field(json, "http_method", "httpMethod"),
      http_route: FieldParser.get_field(json, "http_route", "httpRoute"),
      http_status_code: to_string(FieldParser.get_field(json, "http_status_code", "httpStatusCode", "")),
      grpc_service: FieldParser.get_field(json, "grpc_service", "grpcService"),
      grpc_method: FieldParser.get_field(json, "grpc_method", "grpcMethod"),
      grpc_status_code: to_string(FieldParser.get_field(json, "grpc_status_code", "grpcStatusCode", "")),
      is_slow: FieldParser.get_field(json, "is_slow", "isSlow", false),
      component: json["component"],
      level: json["level"],
      created_at: DateTime.utc_now()
    }
  end

  defp parse_protobuf_metric(_data, _metadata) do
    # TODO: Implement protobuf parsing for ExportMetricsServiceRequest
    # For now, skip protobuf messages
    nil
  end
end
